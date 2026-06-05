import Foundation
import Security
import SQLite3
import SwiftUI

enum CursorUsageProvider {
    static let id = "cursor"

    private static let stateDatabasePath = "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    private static let accessTokenKey = "cursorAuth/accessToken"
    private static let refreshTokenKey = "cursorAuth/refreshToken"
    private static let keychainAccessTokenService = "cursor-access-token"
    private static let keychainRefreshTokenService = "cursor-refresh-token"
    private static let baseURL = "https://api2.cursor.sh"
    private static let usageURL = baseURL + "/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
    private static let planURL = baseURL + "/aiserver.v1.DashboardService/GetPlanInfo"
    private static let refreshURL = baseURL + "/oauth/token"
    private static let creditsURL = baseURL + "/aiserver.v1.DashboardService/GetCreditGrantsBalance"
    private static let stripeURL = "https://cursor.com/api/auth/stripe"
    private static let requestUsageURLs = [
        "https://cursor.com/api/usage",
        "https://cursor.com/api/auth/usage"
    ]
    private static let clientID = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB"
    private static let refreshBuffer: TimeInterval = 5 * 60

    static func loadSnapshot(now: Date = Date()) async -> UsageSnapshot {
        guard AppPreferences.isProviderEnabled(AppPreferences.cursorEnabledKey) else {
            return statusSnapshot(status: "off", color: .gray, message: "Enable Cursor in Settings.")
        }

        do {
            var auth = loadAuthState()
            guard auth.accessToken != nil || auth.refreshToken != nil else {
                return statusSnapshot(status: "missing", color: .orange, message: "Sign in via Cursor app or run `agent login`.")
            }

            if needsRefresh(accessToken: auth.accessToken, now: now) {
                if let refreshed = try await refreshAccessToken(auth: auth) {
                    auth.accessToken = refreshed
                }
            }

            guard let accessToken = auth.accessToken else {
                return statusSnapshot(status: "expired", color: .orange, message: "Cursor token expired. Sign in via Cursor app or run `agent login`.")
            }

            async let usage = fetchUsage(accessToken: accessToken)
            async let planName = fetchPlanName(accessToken: accessToken)
            async let credits = fetchCredits(accessToken: accessToken)
            async let stripeBalance = fetchStripeBalance(accessToken: accessToken)
            async let requestUsage = fetchRequestUsage(accessToken: accessToken)

            return try await buildUsageSnapshot(
                usage: usage,
                planName: (try? planName) ?? "",
                creditGrants: credits,
                stripeBalanceCents: stripeBalance,
                requestUsage: requestUsage
            )
        } catch {
            return statusSnapshot(status: "error", color: .red, message: error.localizedDescription)
        }
    }

    private static func buildUsageSnapshot(
        usage: CursorUsageResponse,
        planName: String,
        creditGrants: CursorCreditGrants?,
        stripeBalanceCents: Double,
        requestUsage: CursorRequestUsage?
    ) -> UsageSnapshot {
        guard usage.enabled != false else {
            return statusSnapshot(status: "inactive", color: .orange, message: "No active Cursor subscription found.")
        }

        let billingPeriodMs = billingPeriodMs(start: usage.billingCycleStart, end: usage.billingCycleEnd)
        let resetsAt = resetText(fromUnixMsString: usage.billingCycleEnd)
        let planLabel = planName.isEmpty ? "Cursor" : planName.capitalized
        var lines: [MetricLine] = []

        let grantTotalCents = creditGrants?.hasCreditGrants == true ? Double(creditGrants?.totalCents ?? 0) : 0
        let grantUsedCents = creditGrants?.hasCreditGrants == true ? Double(creditGrants?.usedCents ?? 0) : 0
        let combinedCreditCents = max(0, grantTotalCents) + stripeBalanceCents
        let hasAPICreditSignal = combinedCreditCents > 0 || grantUsedCents > 0
        if combinedCreditCents > 0 {
            lines.append(MetricLine(
                label: "Credits",
                used: dollars(grantUsedCents),
                limit: dollars(combinedCreditCents),
                format: .dollars,
                resetText: nil
            ))
        }

        if let planUsage = usage.planUsage {
            let totalPercent = totalUsagePercent(planUsage)
            lines.append(MetricLine(
                label: "Total usage",
                used: totalPercent,
                limit: 100,
                format: .percent,
                resetText: resetsAt ?? billingPeriodMs.map { "Current billing cycle · \(Int($0 / 86_400_000))d" }
            ))

            if let autoPercentUsed = planUsage.autoPercentUsed, autoPercentUsed.isFinite {
                lines.append(MetricLine(label: "Auto usage", used: autoPercentUsed, limit: 100, format: .percent, resetText: resetsAt))
            }

            if let apiPercentUsed = planUsage.apiPercentUsed,
               apiPercentUsed.isFinite,
               (apiPercentUsed > 0 || hasAPICreditSignal) {
                lines.append(MetricLine(label: "API usage", used: apiPercentUsed, limit: 100, format: .percent, resetText: resetsAt))
            }
        }

        if let spendLimit = usage.spendLimitUsage {
            let limit = spendLimit.individualLimit ?? spendLimit.pooledLimit ?? 0
            let remaining = spendLimit.individualRemaining ?? spendLimit.pooledRemaining ?? 0
            if limit > 0 {
                lines.append(MetricLine(
                    label: "On-demand",
                    used: dollars(limit - remaining),
                    limit: dollars(limit),
                    format: .dollars,
                    resetText: nil
                ))
            }
        }

        if let requestUsage {
            if let limit = requestUsage.limit, limit > 0 {
                lines.append(MetricLine(
                    label: "Requests",
                    used: requestUsage.used,
                    limit: limit,
                    format: .count("requests"),
                    resetText: requestUsage.label
                ))
            } else {
                lines.append(MetricLine(
                    label: "Requests",
                    used: 0,
                    limit: 1,
                    format: .text,
                    resetText: requestUsage.label,
                    valueOverride: "\(Int(requestUsage.used.rounded())) requests"
                ))
            }
        }

        guard !lines.isEmpty else {
            return statusSnapshot(status: "no data", color: .gray, message: "Cursor returned no usage metrics for this account.")
        }

        return UsageSnapshot(
            id: id,
            name: "Cursor",
            shortName: "CU",
            plan: planLabel,
            status: "live",
            statusColor: .green,
            color: .blue,
            iconName: "CursorIcon",
            lines: lines
        )
    }

    private static func statusSnapshot(status: String, color: Color, message: String) -> UsageSnapshot {
        UsageSnapshot(
            id: id,
            name: "Cursor",
            shortName: "CU",
            plan: "Cursor",
            status: status,
            statusColor: color,
            color: .blue,
            iconName: "CursorIcon",
            lines: [
                MetricLine(label: "Status", used: 0, limit: 1, format: .text, resetText: message, valueOverride: status)
            ],
            message: message
        )
    }

    private static func loadAuthState() -> CursorAuthState {
        let sqliteAccessToken = readStateValue(key: accessTokenKey)
        let sqliteRefreshToken = readStateValue(key: refreshTokenKey)

        if sqliteAccessToken != nil || sqliteRefreshToken != nil {
            return CursorAuthState(accessToken: sqliteAccessToken, refreshToken: sqliteRefreshToken, source: .sqlite)
        }

        let keychainAccessToken = readKeychainValue(service: keychainAccessTokenService)
        let keychainRefreshToken = readKeychainValue(service: keychainRefreshTokenService)
        return CursorAuthState(accessToken: keychainAccessToken, refreshToken: keychainRefreshToken, source: .keychain)
    }

    private static func readStateValue(key: String) -> String? {
        let path = UserHome.expand(stateDatabasePath)
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1;"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { return nil }
        let string = String(cString: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return string.isEmpty ? nil : string
    }

    private static func writeStateValue(key: String, value: String) {
        let path = UserHome.expand(stateDatabasePath)
        guard FileManager.default.fileExists(atPath: path) else { return }

        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            return
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?);"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, value, -1, SQLITE_TRANSIENT)
        sqlite3_step(statement)
    }

    private static func readKeychainValue(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        return value
    }

    private static func writeKeychainValue(service: String, value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]

        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) != errSecSuccess {
            var addQuery = query
            addQuery[kSecValueData as String] = Data(value.utf8)
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    private static func needsRefresh(accessToken: String?, now: Date) -> Bool {
        guard let accessToken, let expiration = jwtExpiration(accessToken) else { return true }
        return expiration.timeIntervalSince(now) <= refreshBuffer
    }

    private static func refreshAccessToken(auth: CursorAuthState) async throws -> String? {
        guard let refreshToken = auth.refreshToken else { return nil }

        let body = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": refreshToken
        ])

        let data = try await request(
            url: refreshURL,
            method: "POST",
            headers: ["Content-Type": "application/json"],
            body: body
        )
        let response = try JSONDecoder().decode(CursorRefreshResponse.self, from: data)

        guard response.shouldLogout != true, let accessToken = response.accessToken, !accessToken.isEmpty else {
            throw CursorError.sessionExpired
        }

        switch auth.source {
        case .sqlite:
            writeStateValue(key: accessTokenKey, value: accessToken)
            if let refreshToken = response.refreshToken, !refreshToken.isEmpty {
                writeStateValue(key: refreshTokenKey, value: refreshToken)
            }
        case .keychain:
            writeKeychainValue(service: keychainAccessTokenService, value: accessToken)
            if let refreshToken = response.refreshToken, !refreshToken.isEmpty {
                writeKeychainValue(service: keychainRefreshTokenService, value: refreshToken)
            }
        }

        return accessToken
    }

    private static func fetchUsage(accessToken: String) async throws -> CursorUsageResponse {
        let data = try await connectPost(url: usageURL, accessToken: accessToken)
        return try JSONDecoder().decode(CursorUsageResponse.self, from: data)
    }

    private static func fetchPlanName(accessToken: String) async throws -> String? {
        let data = try await connectPost(url: planURL, accessToken: accessToken)
        let response = try JSONDecoder().decode(CursorPlanResponse.self, from: data)
        return response.planInfo?.planName
    }

    private static func fetchCredits(accessToken: String) async -> CursorCreditGrants? {
        guard let data = try? await connectPost(url: creditsURL, accessToken: accessToken) else { return nil }
        return try? JSONDecoder().decode(CursorCreditGrants.self, from: data)
    }

    private static func fetchStripeBalance(accessToken: String) async -> Double {
        guard let session = sessionCookie(accessToken: accessToken),
              let data = try? await request(url: stripeURL, method: "GET", headers: ["Cookie": "WorkosCursorSessionToken=\(session.sessionToken)"]),
              let stripe = try? JSONDecoder().decode(CursorStripeResponse.self, from: data),
              let balance = stripe.customerBalance else {
            return 0
        }

        return balance < 0 ? abs(balance) : 0
    }

    private static func fetchRequestUsage(accessToken: String) async -> CursorRequestUsage? {
        guard let session = sessionCookie(accessToken: accessToken) else { return nil }
        let headers = [
            "Accept": "application/json",
            "Cookie": "WorkosCursorSessionToken=\(session.sessionToken)"
        ]

        for url in requestUsageURLs {
            guard let data = try? await request(url: url, method: "GET", headers: headers),
                  let root = try? JSONDecoder().decode(CursorJSONValue.self, from: data),
                  let usage = CursorRequestUsage(root: root) else {
                continue
            }

            return usage
        }

        return nil
    }

    private static func connectPost(url: String, accessToken: String) async throws -> Data {
        try await request(
            url: url,
            method: "POST",
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Content-Type": "application/json",
                "Connect-Protocol-Version": "1"
            ],
            body: Data("{}".utf8)
        )
    }

    private static func request(url: String, method: String, headers: [String: String], body: Data? = nil) async throws -> Data {
        guard let url = URL(string: url) else { throw CursorError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.httpBody = body
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CursorError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw CursorError.sessionExpired }
            throw CursorError.http(http.statusCode)
        }

        return data
    }

    private static func totalUsagePercent(_ planUsage: CursorPlanUsage) -> Double {
        if let totalPercentUsed = planUsage.totalPercentUsed, totalPercentUsed.isFinite {
            return totalPercentUsed
        }

        guard let limit = planUsage.limit, limit > 0 else { return 0 }
        let used = planUsage.totalSpend ?? (limit - (planUsage.remaining ?? 0))
        return min(100, max(0, (used / limit) * 100))
    }

    private static func billingPeriodMs(start: String?, end: String?) -> Double? {
        guard let start = Double(start ?? ""), let end = Double(end ?? ""), end > start else { return nil }
        return end - start
    }

    private static func resetText(fromUnixMsString value: String?) -> String? {
        guard let value, let milliseconds = Double(value) else { return nil }
        let date = Date(timeIntervalSince1970: milliseconds / 1000.0)
        return "Resets " + date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    private static func dollars(_ cents: Double) -> Double {
        cents / 100.0
    }

    private static func jwtExpiration(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2,
              let payloadData = base64URLDecode(String(parts[1])),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let exp = payload["exp"] as? Double else {
            return nil
        }

        return Date(timeIntervalSince1970: exp)
    }

    private static func sessionCookie(accessToken: String) -> (userID: String, sessionToken: String)? {
        let parts = accessToken.split(separator: ".")
        guard parts.count >= 2,
              let payloadData = base64URLDecode(String(parts[1])),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let subject = payload["sub"] as? String else {
            return nil
        }

        let userID = subject.split(separator: "|").last.map(String.init) ?? subject
        return (userID, userID + "%3A%3A" + accessToken)
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = 4 - (base64.count % 4)
        if padding < 4 {
            base64 += String(repeating: "=", count: padding)
        }
        return Data(base64Encoded: base64)
    }

}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private struct CursorAuthState {
    enum Source {
        case sqlite
        case keychain
    }

    var accessToken: String?
    let refreshToken: String?
    let source: Source
}

private struct CursorUsageResponse: Decodable {
    let billingCycleStart: String?
    let billingCycleEnd: String?
    let planUsage: CursorPlanUsage?
    let spendLimitUsage: CursorSpendLimitUsage?
    let enabled: Bool?
}

private struct CursorPlanUsage: Decodable {
    let totalSpend: Double?
    let remaining: Double?
    let limit: Double?
    let autoPercentUsed: Double?
    let apiPercentUsed: Double?
    let totalPercentUsed: Double?
}

private struct CursorSpendLimitUsage: Decodable {
    let pooledLimit: Double?
    let pooledRemaining: Double?
    let individualLimit: Double?
    let individualRemaining: Double?
}

private struct CursorPlanResponse: Decodable {
    let planInfo: CursorPlanInfo?
}

private struct CursorPlanInfo: Decodable {
    let planName: String?
}

private struct CursorCreditGrants: Decodable {
    let hasCreditGrants: Bool?
    let totalCents: Int?
    let usedCents: Int?
}

private struct CursorStripeResponse: Decodable {
    let customerBalance: Double?
}

private struct CursorRequestUsage {
    let used: Double
    let limit: Double?
    let label: String?

    init?(root: CursorJSONValue) {
        let preferredKey = root.objectValue?["includedModelKey"]?.stringValue
        guard let bucket = Self.findBucket(in: root, preferredKey: preferredKey),
              bucket.used >= 0 else {
            return nil
        }

        used = bucket.limit.map { min(bucket.used, $0) } ?? bucket.used
        limit = bucket.limit
        label = bucket.name.map { "Included requests · \($0)" } ?? "Included requests"
    }

    private static func findBucket(in value: CursorJSONValue, preferredKey: String?) -> (used: Double, limit: Double?, name: String?)? {
        if let object = value.objectValue {
            if let preferredKey,
               let preferred = object[preferredKey],
               let bucket = requestBucket(from: preferred, name: preferredKey) {
                return bucket
            }

            if let bucket = requestBucket(from: value, name: preferredKey) {
                return bucket
            }

            for (key, child) in object {
                if let bucket = findBucket(in: child, preferredKey: preferredKey ?? key) {
                    return bucket
                }
            }
        }

        if let array = value.arrayValue {
            for child in array {
                if let bucket = findBucket(in: child, preferredKey: preferredKey) {
                    return bucket
                }
            }
        }

        return nil
    }

    private static func requestBucket(from value: CursorJSONValue, name: String?) -> (used: Double, limit: Double?, name: String?)? {
        guard let object = value.objectValue else { return nil }
        let used = object.number(for: "numRequests")
            ?? object.number(for: "requestsUsed")
            ?? object.number(for: "usedRequests")
            ?? object.number(for: "used")
        let limit = object.number(for: "maxRequestUsage")
            ?? object.number(for: "requestLimit")
            ?? object.number(for: "maxRequests")
            ?? object.number(for: "limit")

        guard let used else { return nil }
        let label = object["includedModelKey"]?.stringValue
            ?? object["modelKey"]?.stringValue
            ?? object["model"]?.stringValue
            ?? name
        return (used, limit, label)
    }
}

private enum CursorJSONValue: Decodable {
    case object([String: CursorJSONValue])
    case array([CursorJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let object = try? container.decode([String: CursorJSONValue].self) {
            self = .object(object)
        } else if let array = try? container.decode([CursorJSONValue].self) {
            self = .array(array)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    var objectValue: [String: CursorJSONValue]? {
        if case .object(let object) = self { object } else { nil }
    }

    var arrayValue: [CursorJSONValue]? {
        if case .array(let array) = self { array } else { nil }
    }

    var stringValue: String? {
        if case .string(let string) = self { string } else { nil }
    }

    var numberValue: Double? {
        switch self {
        case .number(let number):
            number.isFinite ? number : nil
        case .string(let string):
            Double(string)
        default:
            nil
        }
    }
}

private extension Dictionary where Key == String, Value == CursorJSONValue {
    func number(for key: String) -> Double? {
        self[key]?.numberValue
    }
}

private struct CursorRefreshResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let shouldLogout: Bool?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case shouldLogout
    }
}

private enum CursorError: LocalizedError {
    case invalidURL
    case invalidResponse
    case http(Int)
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Invalid Cursor URL."
        case .invalidResponse:
            "Cursor returned an invalid response."
        case .http(let status):
            "Cursor request failed with HTTP \(status)."
        case .sessionExpired:
            "Cursor session expired. Sign in via Cursor app or run `agent login`."
        }
    }
}
