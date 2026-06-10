import Foundation
import Security

struct ClaudeOAuthUsageClient {
    private static let credentialsPath = UserHome.expand("~/.claude/.credentials.json")
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let refreshBuffer: TimeInterval = 5 * 60

    func loadUsage(now: Date = Date()) async throws -> ClaudeOAuthUsageResult {
        var credentials = try loadCredentials()
        if credentials.expiresAt.map({ Date(timeIntervalSince1970: Double($0) / 1000).timeIntervalSince(now) < Self.refreshBuffer }) == true,
           let refreshToken = credentials.refreshToken {
            credentials = try await refresh(credentials: credentials, refreshToken: refreshToken)
            try? save(credentials: credentials)
        }

        guard let token = credentials.accessToken, !token.isEmpty else { throw ClaudeOAuthError.missingCredentials }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.69", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeOAuthError.badResponse }
        if http.statusCode == 429 {
            throw ClaudeOAuthError.rateLimited(http.value(forHTTPHeaderField: "Retry-After"))
        }
        guard (200..<300).contains(http.statusCode) else { throw ClaudeOAuthError.http(http.statusCode) }
        return ClaudeOAuthUsageResult(credentials: credentials, usage: try JSONDecoder.anthropic.decode(ClaudeOAuthUsageResponse.self, from: data))
    }

    private func loadCredentials() throws -> ClaudeOAuthCredentials {
        if let envToken = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"], !envToken.isEmpty {
            return ClaudeOAuthCredentials(accessToken: envToken, refreshToken: nil, expiresAt: nil, subscriptionType: nil, rateLimitTier: nil)
        }

        // Match OpenUsage/Claude Code behavior: recent Claude Code keeps the
        // current macOS session in Keychain and may leave a stale/missing file.
        // Prefer Keychain when it contains a valid credentials JSON blob.
        if let keychain = keychainCredentials() {
            return keychain
        }

        if let data = FileManager.default.contents(atPath: Self.credentialsPath),
           let file = try? JSONDecoder().decode(ClaudeCredentialsFile.self, from: data) {
            return file.claudeAiOauth
        }

        throw ClaudeOAuthError.missingCredentials
    }

    private func save(credentials: ClaudeOAuthCredentials) throws {
        let file = ClaudeCredentialsFile(claudeAiOauth: credentials)
        let data = try JSONEncoder().encode(file)
        try data.write(to: URL(fileURLWithPath: Self.credentialsPath), options: .atomic)
    }

    private func refresh(credentials: ClaudeOAuthCredentials, refreshToken: String) async throws -> ClaudeOAuthCredentials {
        var request = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RefreshRequest(grantType: "refresh_token", refreshToken: refreshToken, clientID: Self.clientID))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw ClaudeOAuthError.refreshFailed }
        let refreshed = try JSONDecoder().decode(RefreshResponse.self, from: data)
        let expiresAt = refreshed.expiresIn.map { Int64(Date().addingTimeInterval(TimeInterval($0)).timeIntervalSince1970 * 1000) } ?? credentials.expiresAt
        return ClaudeOAuthCredentials(accessToken: refreshed.accessToken, refreshToken: refreshed.refreshToken ?? refreshToken, expiresAt: expiresAt, subscriptionType: credentials.subscriptionType, rateLimitTier: credentials.rateLimitTier)
    }

    private func keychainCredentials() -> ClaudeOAuthCredentials? {
        for service in keychainServiceCandidates() {
            var item: CFTypeRef?
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data,
                  let text = String(data: data, encoding: .utf8),
                  let file = parseCredentials(text: text) else { continue }
            return file.claudeAiOauth
        }
        return nil
    }

    private func parseCredentials(text: String) -> ClaudeCredentialsFile? {
        if let data = text.data(using: .utf8),
           let file = try? JSONDecoder().decode(ClaudeCredentialsFile.self, from: data) {
            return file
        }

        var hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex.removeFirst(2) }
        guard hex.count.isMultiple(of: 2), hex.range(of: #"^[0-9a-fA-F]+$"#, options: .regularExpression) != nil else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        guard let decoded = String(bytes: bytes, encoding: .utf8),
              let data = decoded.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ClaudeCredentialsFile.self, from: data)
    }

    private func keychainServiceCandidates() -> [String] {
        // Default Claude Code path. OpenUsage also tries a hashed suffix when
        // CLAUDE_CONFIG_DIR is set; the default service is still the important
        // path for this app and avoids pulling in hashing just for fallback.
        ["Claude Code-credentials"]
    }
}

struct ClaudeOAuthUsageResult {
    let credentials: ClaudeOAuthCredentials
    let usage: ClaudeOAuthUsageResponse
}

struct ClaudeCredentialsFile: Codable { let claudeAiOauth: ClaudeOAuthCredentials }

struct ClaudeOAuthCredentials: Codable {
    let accessToken: String?
    let refreshToken: String?
    let expiresAt: Int64?
    let subscriptionType: String?
    let rateLimitTier: String?
}

struct ClaudeOAuthUsageResponse: Decodable {
    let fiveHour: ClaudeOAuthWindow?
    let sevenDay: ClaudeOAuthWindow?
    let sevenDaySonnet: ClaudeOAuthWindow?
    let sevenDayOmelette: ClaudeOAuthWindow?
    let extraUsage: ClaudeExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour", sevenDay = "seven_day", sevenDaySonnet = "seven_day_sonnet", sevenDayOmelette = "seven_day_omelette", extraUsage = "extra_usage"
    }
}

struct ClaudeOAuthWindow: Decodable {
    let utilization: Double?
    let resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}
struct ClaudeExtraUsage: Decodable { let usedCents: Double?; let limitCents: Double?; enum CodingKeys: String, CodingKey { case usedCents = "used_cents", limitCents = "limit_cents" } }

private struct RefreshRequest: Encodable { let grantType: String; let refreshToken: String; let clientID: String; enum CodingKeys: String, CodingKey { case grantType = "grant_type", refreshToken = "refresh_token", clientID = "client_id" } }
private struct RefreshResponse: Decodable { let accessToken: String; let refreshToken: String?; let expiresIn: Int?; enum CodingKeys: String, CodingKey { case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in" } }

enum ClaudeOAuthError: LocalizedError {
    case missingCredentials, badResponse, http(Int), refreshFailed, rateLimited(String?)
    var errorDescription: String? {
        switch self {
        case .missingCredentials: "Claude OAuth credentials not found."
        case .badResponse: "Claude usage returned an invalid response."
        case .http(let code): "Claude usage request failed (HTTP \(code))."
        case .refreshFailed: "Claude OAuth token refresh failed."
        case .rateLimited(let retry): retry.map { "Claude usage is rate limited. Retry after \($0)s." } ?? "Claude usage is rate limited."
        }
    }
}

private extension JSONDecoder {
    static var anthropic: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter.oauthWithFractions.date(from: value) ?? ISO8601DateFormatter.oauthWithoutFractions.date(from: value) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid ISO8601 date"))
        }
        return decoder
    }
}

private extension ISO8601DateFormatter {
    static let oauthWithFractions: ISO8601DateFormatter = { let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return formatter }()
    static let oauthWithoutFractions: ISO8601DateFormatter = { let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime]; return formatter }()
}
