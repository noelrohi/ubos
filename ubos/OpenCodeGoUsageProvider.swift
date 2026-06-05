import Foundation
import SQLite3
import SwiftUI

enum OpenCodeGoUsageProvider {
    static let id = "opencode-go"
    private static let providerID = id
    private static let authPath = "~/.local/share/opencode/auth.json"
    private static let databasePath = "~/.local/share/opencode/opencode.db"
    private static let fiveHoursMs = 5.0 * 60.0 * 60.0 * 1000.0
    private static let weekMs = 7.0 * 24.0 * 60.0 * 60.0 * 1000.0

    private static let sessionLimit = 12.0
    private static let weeklyLimit = 30.0
    private static let monthlyLimit = 60.0
    private static var earliestUsageCache: Double?

    private static let historyCTE = """
        WITH history AS (
          SELECT
            CAST(COALESCE(json_extract(data, '$.time.created'), time_created) AS INTEGER) AS createdMs,
            CAST(json_extract(data, '$.cost') AS REAL) AS cost
          FROM message
          WHERE json_valid(data)
            AND json_extract(data, '$.providerID') = 'opencode-go'
            AND json_extract(data, '$.role') = 'assistant'
            AND json_type(data, '$.cost') IN ('integer', 'real')
        )
        """

    static func loadSnapshot(now: Date = Date()) -> UsageSnapshot {
        guard AppPreferences.isProviderEnabled(AppPreferences.openCodeGoEnabledKey) else {
            return statusSnapshot(status: "off", color: .gray, message: "Enable OpenCode Go in Settings.")
        }

        let authDetected = hasAuthKey()
        let usageResult = loadUsage(now: now)

        switch usageResult {
        case .success(let usage):
            guard authDetected || usage.hasRows else {
                return statusSnapshot(status: "missing", color: .orange, message: "Log in with OpenCode Go or use it locally first.")
            }

            return usageSnapshot(usage: usage)

        case .failure(let error):
            guard authDetected else {
                return statusSnapshot(status: "missing", color: .orange, message: "OpenCode Go data not found.")
            }

            return statusSnapshot(status: "no data", color: .gray, message: error.localizedDescription)
        }
    }

    private static func usageSnapshot(usage: UsageTotals) -> UsageSnapshot {
        return UsageSnapshot(
            id: providerID,
            name: "OpenCode Go",
            shortName: "OG",
            plan: "Go",
            status: usage.hasRows ? "live" : "ready",
            statusColor: usage.hasRows ? .green : .blue,
            color: .black,
            iconName: "OpenCodeIcon",
            lines: [
                MetricLine(
                    label: "Session",
                    used: percent(usage.sessionCost, limit: sessionLimit),
                    limit: 100,
                    format: .percent,
                    resetText: "$\(money(usage.sessionCost)) / $\(money(sessionLimit)) · 5h rolling"
                ),
                MetricLine(
                    label: "Weekly",
                    used: percent(usage.weeklyCost, limit: weeklyLimit),
                    limit: 100,
                    format: .percent,
                    resetText: "$\(money(usage.weeklyCost)) / $\(money(weeklyLimit)) · resets Monday UTC"
                ),
                MetricLine(
                    label: "Monthly",
                    used: percent(usage.monthlyCost, limit: monthlyLimit),
                    limit: 100,
                    format: .percent,
                    resetText: "$\(money(usage.monthlyCost)) / $\(money(monthlyLimit)) · anchored to first local usage"
                )
            ]
        )
    }

    private static func statusSnapshot(status: String, color: Color, message: String) -> UsageSnapshot {
        UsageSnapshot(
            id: providerID,
            name: "OpenCode Go",
            shortName: "OG",
            plan: "Go",
            status: status,
            statusColor: color,
            color: .black,
            iconName: "OpenCodeIcon",
            lines: [
                MetricLine(label: "Status", used: 0, limit: 1, format: .text, resetText: message, valueOverride: status)
            ],
            message: message
        )
    }

    private static func hasAuthKey() -> Bool {
        let url = URL(fileURLWithPath: UserHome.expand(authPath))
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = json[providerID] as? [String: Any],
              let key = entry["key"] as? String else {
            return false
        }

        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func loadUsage(now: Date) -> Result<UsageTotals, OpenCodeGoError> {
        let path = UserHome.expand(databasePath)
        guard FileManager.default.fileExists(atPath: path) else {
            return .failure(.databaseMissing)
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open SQLite database."
            if let database {
                sqlite3_close(database)
            }
            return .failure(.sqlite(message))
        }

        defer { sqlite3_close(database) }

        let earliestMs = earliestUsageCache ?? earliestUsageMs(database: database)
        if earliestUsageCache == nil, earliestMs != nil {
            earliestUsageCache = earliestMs
        }
        let nowMs = now.timeIntervalSince1970 * 1000.0
        let monthlyBounds = anchoredMonthBounds(nowMs: nowMs, anchorMs: earliestMs)
        let weeklyStartMs = startOfUTCWeek(now: now)

        var statement: OpaquePointer?
        let sql = historyCTE + """
            SELECT
              COALESCE(SUM(CASE WHEN createdMs >= ? AND createdMs < ? THEN cost ELSE 0 END), 0) AS sessionCost,
              COALESCE(SUM(CASE WHEN createdMs >= ? AND createdMs < ? THEN cost ELSE 0 END), 0) AS weeklyCost,
              COALESCE(SUM(CASE WHEN createdMs >= ? AND createdMs < ? THEN cost ELSE 0 END), 0) AS monthlyCost,
              COUNT(*) AS rowCount
            FROM history;
            """

        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return .failure(.sqlite(String(cString: sqlite3_errmsg(database))))
        }

        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, nowMs - fiveHoursMs)
        sqlite3_bind_double(statement, 2, nowMs)
        sqlite3_bind_double(statement, 3, weeklyStartMs)
        sqlite3_bind_double(statement, 4, weeklyStartMs + weekMs)
        sqlite3_bind_double(statement, 5, monthlyBounds.startMs)
        sqlite3_bind_double(statement, 6, monthlyBounds.endMs)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return .failure(.sqlite(String(cString: sqlite3_errmsg(database))))
        }

        return .success(UsageTotals(
            sessionCost: roundedMoney(sqlite3_column_double(statement, 0)),
            weeklyCost: roundedMoney(sqlite3_column_double(statement, 1)),
            monthlyCost: roundedMoney(sqlite3_column_double(statement, 2)),
            rowCount: Int(sqlite3_column_int64(statement, 3))
        ))
    }

    private static func earliestUsageMs(database: OpaquePointer?) -> Double? {
        var statement: OpaquePointer?
        let sql = historyCTE + "SELECT MIN(createdMs) FROM history;"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else {
            return nil
        }

        let value = sqlite3_column_double(statement, 0)
        return value > 0 ? value : nil
    }

    private static func roundedMoney(_ value: Double) -> Double {
        (value * 10000).rounded() / 10000
    }

    private static func percent(_ used: Double, limit: Double) -> Double {
        guard limit > 0 else { return 0 }
        return min(100, max(0, (used / limit) * 100))
    }

    private static func money(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private static func startOfUTCWeek(now: Date) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        let start = calendar.date(from: components) ?? now
        return start.timeIntervalSince1970 * 1000.0
    }

    private static func anchoredMonthBounds(nowMs: Double, anchorMs: Double?) -> (startMs: Double, endMs: Double) {
        guard let anchorMs else {
            return calendarMonthBounds(nowMs: nowMs)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let now = Date(timeIntervalSince1970: nowMs / 1000.0)
        let anchor = Date(timeIntervalSince1970: anchorMs / 1000.0)
        let anchorComponents = calendar.dateComponents([.day, .hour, .minute, .second, .nanosecond], from: anchor)
        let nowComponents = calendar.dateComponents([.year, .month], from: now)

        guard let year = nowComponents.year, let month = nowComponents.month else {
            return calendarMonthBounds(nowMs: nowMs)
        }

        var start = anchoredMonth(year: year, month: month, anchor: anchorComponents, calendar: calendar)
        if start.timeIntervalSince1970 * 1000.0 > nowMs,
           let previous = calendar.date(byAdding: .month, value: -1, to: start) {
            start = previous
        }

        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start.addingTimeInterval(30 * 24 * 60 * 60)
        return (start.timeIntervalSince1970 * 1000.0, end.timeIntervalSince1970 * 1000.0)
    }

    private static func calendarMonthBounds(nowMs: Double) -> (startMs: Double, endMs: Double) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let now = Date(timeIntervalSince1970: nowMs / 1000.0)
        let components = calendar.dateComponents([.year, .month], from: now)
        let start = calendar.date(from: components) ?? now
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start.addingTimeInterval(30 * 24 * 60 * 60)
        return (start.timeIntervalSince1970 * 1000.0, end.timeIntervalSince1970 * 1000.0)
    }

    private static func anchoredMonth(year: Int, month: Int, anchor: DateComponents, calendar: Calendar) -> Date {
        let rangeDate = calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: year, month: month, day: 1)) ?? Date()
        let maxDay = calendar.range(of: .day, in: .month, for: rangeDate)?.count ?? 28

        return calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: min(anchor.day ?? 1, maxDay),
            hour: anchor.hour ?? 0,
            minute: anchor.minute ?? 0,
            second: anchor.second ?? 0,
            nanosecond: anchor.nanosecond ?? 0
        )) ?? rangeDate
    }

    private struct UsageTotals {
        let sessionCost: Double
        let weeklyCost: Double
        let monthlyCost: Double
        let rowCount: Int

        var hasRows: Bool {
            rowCount > 0
        }
    }

    private enum OpenCodeGoError: LocalizedError {
        case databaseMissing
        case sqlite(String)

        var errorDescription: String? {
            switch self {
            case .databaseMissing:
                "OpenCode database was not found at ~/.local/share/opencode/opencode.db."
            case .sqlite(let message):
                message
            }
        }
    }
}
