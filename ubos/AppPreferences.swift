import Foundation
import Darwin

enum AppPreferences {
    static let refreshIntervalMinutesKey = "refreshIntervalMinutes"
    static let usageDisplayModeKey = "usageDisplayMode"
    static let openCodeGoEnabledKey = "openCodeGoEnabled"
    static let cursorEnabledKey = "cursorEnabled"
    static let codexEnabledKey = "codexEnabled"
    static let claudeCodeEnabledKey = "claudeCodeEnabled"

    static var refreshIntervalMinutes: Int {
        let stored = UserDefaults.standard.integer(forKey: refreshIntervalMinutesKey)
        return stored > 0 ? stored : 15
    }

    static func isProviderEnabled(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil || UserDefaults.standard.bool(forKey: key)
    }
}

enum KeychainStore {
    static func read(service: String) -> String? {
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

    static func write(service: String, value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            delete(service: service)
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let attributes: [String: Any] = [kSecValueData as String: Data(trimmed.utf8)]

        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) != errSecSuccess {
            var addQuery = query
            addQuery[kSecValueData as String] = Data(trimmed.utf8)
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    static func delete(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum UserHome {
    static let path: String = {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else {
            return NSHomeDirectory()
        }
        return String(cString: directory)
    }()

    static func expand(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return Self.path + String(path.dropFirst())
    }
}
