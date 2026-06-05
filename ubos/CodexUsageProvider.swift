import Foundation
import SwiftUI

enum CodexUsageProvider {
    static let id = "codex"

    private static let keychainService = "Codex Auth"
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let refreshURL = "https://auth.openai.com/oauth/token"
    private static let usageURL = "https://chatgpt.com/backend-api/wham/usage"
    private static let refreshAge: TimeInterval = 8 * 24 * 60 * 60

    static func loadSnapshot(now: Date = Date()) async -> UsageSnapshot {
        guard AppPreferences.isProviderEnabled(AppPreferences.codexEnabledKey) else {
            return statusSnapshot(status: "off", color: .gray, message: "Enable Codex in Settings.")
        }

        do {
            var authState = try loadAuthState()

            guard authState.auth.tokens?.accessToken != nil || authState.auth.tokens?.refreshToken != nil else {
                if authState.auth.openAIAPIKey != nil {
                    return statusSnapshot(status: "api key", color: .orange, message: "Codex usage is not available for API-key auth. Run `codex` to authenticate.")
                }
                return statusSnapshot(status: "missing", color: .orange, message: "Run `codex` to authenticate.")
            }

            if authState.auth.tokens?.accessToken == nil || needsRefresh(authState.auth, now: now) {
                try await refresh(authState: &authState)
            }

            do {
                return try await usageSnapshot(authState: authState)
            } catch CodexError.sessionExpired {
                try await refresh(authState: &authState)
                return try await usageSnapshot(authState: authState)
            }
        } catch {
            return statusSnapshot(status: "error", color: .red, message: error.localizedDescription)
        }
    }

    private static func usageSnapshot(authState: CodexAuthState) async throws -> UsageSnapshot {
        guard let accessToken = authState.auth.tokens?.accessToken else { throw CodexError.notLoggedIn }

        var request = URLRequest(url: URL(string: usageURL)!)
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ubos", forHTTPHeaderField: "User-Agent")

        if let accountID = authState.auth.tokens?.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CodexError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw CodexError.sessionExpired }
            throw CodexError.http(http.statusCode)
        }

        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        var lines: [MetricLine] = []

        if let primary = usage.rateLimit?.primaryWindow {
            lines.append(progressLine(label: "Session", window: primary, defaultPeriodSeconds: 18_000))
        }

        if let secondary = usage.rateLimit?.secondaryWindow {
            lines.append(progressLine(label: "Weekly", window: secondary, defaultPeriodSeconds: 604_800))
        }

        if let codeReviewRateLimit = usage.codeReviewRateLimit {
            if let review = codeReviewRateLimit.primaryWindow {
                lines.append(progressLine(label: "Reviews", window: review, defaultPeriodSeconds: 604_800))
            } else {
                lines.append(MetricLine(
                    label: "Reviews",
                    used: 0,
                    limit: 1,
                    format: .text,
                    resetText: "No review quota returned by WHAM.",
                    valueOverride: "not returned"
                ))
            }
        } else {
            lines.append(MetricLine(
                label: "Reviews",
                used: 0,
                limit: 1,
                format: .text,
                resetText: "No review quota returned by WHAM.",
                valueOverride: "not returned"
            ))
        }

        if let credits = usage.credits, credits.unlimited != true {
            let balance = credits.balance ?? 0
            lines.append(MetricLine(
                label: "Credits",
                used: max(0, 1000 - balance),
                limit: 1000,
                format: .count("credits"),
                resetText: "\(balance.formatted(.number.precision(.fractionLength(0...2)))) credits remaining"
            ))
        }

        if lines.isEmpty {
            lines.append(MetricLine(label: "Status", used: 0, limit: 1, format: .text, resetText: "No Codex usage data returned.", valueOverride: "no data"))
        }

        return UsageSnapshot(
            id: id,
            name: "Codex",
            shortName: "CX",
            plan: planLabel(usage.planType),
            status: "live",
            statusColor: .green,
            color: Color(red: 0.45, green: 0.67, blue: 0.61),
            iconName: "OpenAIIcon",
            lines: lines
        )
    }

    private static func progressLine(label: String, window: CodexWindow, defaultPeriodSeconds: Int) -> MetricLine {
        MetricLine(
            label: label,
            used: Double(window.usedPercent ?? 0),
            limit: 100,
            format: .percent,
            resetText: resetText(window: window, defaultPeriodSeconds: defaultPeriodSeconds)
        )
    }

    private static func resetText(window: CodexWindow, defaultPeriodSeconds: Int) -> String? {
        if let resetAt = window.resetAt {
            let date = Date(timeIntervalSince1970: TimeInterval(resetAt))
            return "Resets " + date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        }

        if let resetAfter = window.resetAfterSeconds {
            let date = Date(timeIntervalSinceNow: TimeInterval(resetAfter))
            return "Resets " + date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        }

        return "\(defaultPeriodSeconds / 3600)h window"
    }

    private static func planLabel(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "Codex" }
        switch raw.lowercased() {
        case "prolite": return "Pro 5x"
        case "pro": return "Pro 20x"
        default: return raw.capitalized
        }
    }

    private static func loadAuthState() throws -> CodexAuthState {
        for path in authPaths() {
            let expanded = UserHome.expand(path)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: expanded)) else { continue }
            if let auth = try? JSONDecoder().decode(CodexAuth.self, from: data), auth.hasTokenLikeAuth {
                return CodexAuthState(auth: auth, source: .file(expanded))
            }
        }

        if let value = KeychainStore.read(service: keychainService),
           let data = codexKeychainData(value),
           let auth = try? JSONDecoder().decode(CodexAuth.self, from: data),
           auth.hasTokenLikeAuth {
            return CodexAuthState(auth: auth, source: .keychain)
        }

        throw CodexError.notLoggedIn
    }

    private static func authPaths() -> [String] {
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"], !codexHome.isEmpty {
            return [codexHome.replacingOccurrences(of: "/+$", with: "", options: .regularExpression) + "/auth.json"]
        }

        return ["~/.config/codex/auth.json", "~/.codex/auth.json"]
    }

    private static func needsRefresh(_ auth: CodexAuth, now: Date) -> Bool {
        guard let lastRefresh = auth.lastRefresh, let date = ISO8601DateFormatter().date(from: lastRefresh) else { return true }
        return now.timeIntervalSince(date) > refreshAge
    }

    private static func refresh(authState: inout CodexAuthState) async throws {
        guard let refreshToken = authState.auth.tokens?.refreshToken else { throw CodexError.sessionExpired }

        var request = URLRequest(url: URL(string: refreshURL)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "grant_type=refresh_token&client_id=\(Self.percentEncode(clientID))&refresh_token=\(Self.percentEncode(refreshToken))"
        request.httpBody = Data(body.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CodexError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw CodexError.sessionExpired }

        let refresh = try JSONDecoder().decode(CodexRefreshResponse.self, from: data)
        guard let accessToken = refresh.accessToken, !accessToken.isEmpty else { throw CodexError.sessionExpired }

        var tokens = authState.auth.tokens ?? CodexTokens(accessToken: nil, refreshToken: nil, idToken: nil, accountID: nil)
        tokens.accessToken = accessToken
        if let refreshToken = refresh.refreshToken { tokens.refreshToken = refreshToken }
        if let idToken = refresh.idToken { tokens.idToken = idToken }

        authState.auth.tokens = tokens
        authState.auth.lastRefresh = ISO8601DateFormatter().string(from: Date())
        try persist(authState)
    }

    private static func persist(_ authState: CodexAuthState) throws {
        let updatedAuth = try authDictionary(authState.auth)
        let data = try mergedAuthData(existingData: existingAuthData(for: authState.source), updatedAuth: updatedAuth)

        switch authState.source {
        case .file(let path):
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        case .keychain:
            guard let value = String(data: data, encoding: .utf8) else { return }
            KeychainStore.write(service: keychainService, value: value)
        }
    }

    private static func mergedAuthData(existingData: Data?, updatedAuth: [String: Any]) throws -> Data {
        var root: [String: Any]
        if let existingData,
           let existing = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
            root = existing
        } else {
            root = [:]
        }

        for (key, value) in updatedAuth where key != "tokens" {
            root[key] = value
        }

        if let updatedTokens = updatedAuth["tokens"] as? [String: Any] {
            var tokens = root["tokens"] as? [String: Any] ?? [:]
            for (key, value) in updatedTokens {
                tokens[key] = value
            }
            root["tokens"] = tokens
        }

        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    private static func authDictionary(_ auth: CodexAuth) throws -> [String: Any] {
        let data = try JSONEncoder().encode(auth)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func existingAuthData(for source: CodexAuthState.Source) -> Data? {
        switch source {
        case .file(let path):
            return try? Data(contentsOf: URL(fileURLWithPath: path))
        case .keychain:
            if let value = KeychainStore.read(service: keychainService) {
                return codexKeychainData(value)
            }
            return nil
        }
    }

    private static func codexKeychainData(_ value: String) -> Data? {
        if let data = value.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }

        var hex = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex.removeFirst(2) }
        guard hex.count.isMultiple(of: 2), hex.allSatisfy({ $0.isHexDigit }) else { return nil }

        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    private static func statusSnapshot(status: String, color: Color, message: String) -> UsageSnapshot {
        UsageSnapshot(
            id: id,
            name: "Codex",
            shortName: "CX",
            plan: "Codex",
            status: status,
            statusColor: color,
            color: Color(red: 0.45, green: 0.67, blue: 0.61),
            iconName: "OpenAIIcon",
            lines: [
                MetricLine(label: "Status", used: 0, limit: 1, format: .text, resetText: message, valueOverride: status)
            ],
            message: message
        )
    }

    private static func percentEncode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func authJSONHasTokenLikeAuthForTesting(_ data: Data) -> Bool {
        guard let auth = try? JSONDecoder().decode(CodexAuth.self, from: data) else { return false }
        return auth.hasTokenLikeAuth
    }

    static func mergedAuthJSONForTesting(
        existingData: Data,
        accessToken: String,
        refreshToken: String?,
        idToken: String?,
        accountID: String?,
        lastRefresh: String
    ) throws -> Data {
        let auth = CodexAuth(
            openAIAPIKey: nil,
            tokens: CodexTokens(
                accessToken: accessToken,
                refreshToken: refreshToken,
                idToken: idToken,
                accountID: accountID
            ),
            lastRefresh: lastRefresh
        )
        return try mergedAuthData(existingData: existingData, updatedAuth: authDictionary(auth))
    }

}

private struct CodexAuthState {
    enum Source {
        case file(String)
        case keychain
    }

    var auth: CodexAuth
    let source: Source
}

private struct CodexAuth: Codable {
    let openAIAPIKey: String?
    var tokens: CodexTokens?
    var lastRefresh: String?

    var hasTokenLikeAuth: Bool {
        tokens?.accessToken != nil || tokens?.refreshToken != nil || openAIAPIKey != nil
    }

    private enum CodingKeys: String, CodingKey {
        case openAIAPIKey = "OPENAI_API_KEY"
        case tokens
        case lastRefresh = "last_refresh"
    }
}

private struct CodexTokens: Codable {
    var accessToken: String?
    var refreshToken: String?
    var idToken: String?
    var accountID: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case accountID = "account_id"
    }
}

private struct CodexRefreshResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let idToken: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
    }
}

private struct CodexUsageResponse: Decodable {
    let planType: String?
    let rateLimit: CodexRateLimit?
    let codeReviewRateLimit: CodexCodeReviewRateLimit?
    let credits: CodexCredits?

    private enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case codeReviewRateLimit = "code_review_rate_limit"
        case credits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        planType = try? container.decodeIfPresent(String.self, forKey: .planType)
        rateLimit = try? container.decodeIfPresent(CodexRateLimit.self, forKey: .rateLimit)
        codeReviewRateLimit = try? container.decodeIfPresent(CodexCodeReviewRateLimit.self, forKey: .codeReviewRateLimit)
        credits = try? container.decodeIfPresent(CodexCredits.self, forKey: .credits)
    }
}

private struct CodexRateLimit: Decodable {
    let primaryWindow: CodexWindow?
    let secondaryWindow: CodexWindow?

    private enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

private struct CodexCodeReviewRateLimit: Decodable {
    let primaryWindow: CodexWindow?

    private enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
    }
}

private struct CodexWindow: Decodable {
    let usedPercent: Double?
    let resetAt: Double?
    let resetAfterSeconds: Double?
    let limitWindowSeconds: Double?

    private enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetAt = "reset_at"
        case resetAfterSeconds = "reset_after_seconds"
        case limitWindowSeconds = "limit_window_seconds"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usedPercent = container.flexibleDouble(forKey: .usedPercent)
        resetAt = container.flexibleDouble(forKey: .resetAt)
        resetAfterSeconds = container.flexibleDouble(forKey: .resetAfterSeconds)
        limitWindowSeconds = container.flexibleDouble(forKey: .limitWindowSeconds)
    }
}

private struct CodexCredits: Decodable {
    let hasCredits: Bool?
    let unlimited: Bool?
    let balance: Double?

    private enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case unlimited
        case balance
    }
}

private extension KeyedDecodingContainer {
    func flexibleDouble(forKey key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Double(value)
        }
        return nil
    }
}

private enum CodexError: LocalizedError {
    case notLoggedIn
    case sessionExpired
    case invalidResponse
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            "Not logged in. Run `codex` to authenticate."
        case .sessionExpired:
            "Codex session expired. Run `codex` to log in again."
        case .invalidResponse:
            "Codex returned an invalid response."
        case .http(let status):
            "Codex request failed with HTTP \(status)."
        }
    }
}
