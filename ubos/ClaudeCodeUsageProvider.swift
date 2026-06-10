import Foundation
import SwiftUI

enum ClaudeCodeUsageProvider {
    static let id = "claude-code"

    static func loadSnapshot(now: Date = Date()) async -> UsageSnapshot {
        guard AppPreferences.isProviderEnabled(AppPreferences.claudeCodeEnabledKey) else {
            return snapshot(status: "disabled", statusColor: .secondary, plan: "Claude Code", lines: [
                MetricLine(label: "Status", used: 0, limit: 1, format: .text, resetText: "Enable Claude Code in Settings.", valueOverride: "disabled")
            ], message: "Claude Code usage is disabled.")
        }

        let usageRecords = localUsageRecords()
        let localLines = localStatsLines(records: usageRecords, now: now)

        do {
            let result = try await ClaudeOAuthUsageClient().loadUsage(now: now)
            var lines = usageLines(from: result.usage, now: now)
            lines.append(contentsOf: localLines)
            return snapshot(status: "ok", statusColor: .green, plan: planLabel(credentials: result.credentials), lines: lines, message: "Live Claude limits plus local ccusage-style cost estimates.")
        } catch ClaudeOAuthError.rateLimited {
            var lines = localFallbackLines(records: usageRecords, now: now)
            lines.append(contentsOf: localLines)
            return snapshot(status: "rate limited", statusColor: .orange, plan: "Claude Code", lines: lines, message: "Claude usage endpoint is rate limited. Showing local estimates.")
        } catch {
            let lines = localFallbackLines(records: usageRecords, now: now) + localLines
            if !lines.isEmpty {
                return snapshot(status: "local", statusColor: .orange, plan: "Claude Code", lines: lines, message: "Could not load live Claude limits. Showing local estimates.")
            }
            return snapshot(status: "missing", statusColor: .orange, plan: "Claude Code", lines: [
                MetricLine(label: "Status", used: 0, limit: 1, format: .text, resetText: "No Claude credentials or JSONL usage found.", valueOverride: "missing")
            ], message: "Sign in to Claude Code, or allow ubos to read ~/.claude/projects.")
        }
    }

    private static func snapshot(status: String, statusColor: Color, plan: String, lines: [MetricLine], message: String?) -> UsageSnapshot {
        UsageSnapshot(id: id, name: "Claude Code", shortName: "CC", plan: plan, status: status, statusColor: statusColor, color: Color(red: 0.86, green: 0.45, blue: 0.25), iconName: "ClaudeIcon", lines: lines, message: message)
    }

    private static func usageLines(from usage: ClaudeOAuthUsageResponse, now: Date) -> [MetricLine] {
        var lines: [MetricLine] = []
        appendWindow(&lines, label: "Session", window: usage.fiveHour, now: now)
        appendWindow(&lines, label: "Weekly", window: usage.sevenDay, now: now)
        appendWindow(&lines, label: "Weekly Sonnet", window: usage.sevenDaySonnet, now: now)
        appendWindow(&lines, label: "Claude Design", window: usage.sevenDayOmelette, now: now)
        if let extra = usage.extraUsage, let used = extra.usedCents, used > 0 {
            let limit = max(extra.limitCents ?? 0, used)
            lines.append(MetricLine(label: "Extra usage", used: used / 100, limit: max(0.01, limit / 100), format: .dollars, resetText: nil))
        }
        return lines
    }

    private static func appendWindow(_ lines: inout [MetricLine], label: String, window: ClaudeOAuthWindow?, now: Date) {
        guard let utilization = window?.utilization else { return }
        lines.append(MetricLine(label: label, used: utilization, limit: 100, format: .percent, resetText: window?.resetsAt.map { "Resets in \(duration(from: now, to: $0))" }))
    }

    private static func localUsageRecords() -> [Record] {
        let files = [UserHome.expand("~/.claude/projects"), UserHome.expand("~/.config/claude/projects")].flatMap { jsonlFiles(in: $0) }
        var seen = Set<String>()
        var records: [Record] = []
        for file in files {
            for record in parseRecords(path: file) where record.hasUsage && !record.model.lowercased().contains("<synthetic>") {
                let key = record.dedupKey ?? "\(file):\(record.timestamp.timeIntervalSince1970):\(record.model):\(record.usage.inputTokens):\(record.usage.outputTokens)"
                if seen.insert(key).inserted { records.append(record) }
            }
        }
        return records.sorted { $0.timestamp < $1.timestamp }
    }

    private static func localStatsLines(records: [Record], now: Date) -> [MetricLine] {
        guard !records.isEmpty else { return [] }
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
        let monthStart = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let today = aggregate(records.filter { $0.timestamp >= todayStart })
        let yesterday = aggregate(records.filter { $0.timestamp >= yesterdayStart && $0.timestamp < todayStart })
        let month = aggregate(records.filter { $0.timestamp >= monthStart })
        return [
            textLine("Today", today),
            textLine("Yesterday", yesterday),
            textLine("Last 30 Days", month)
        ]
    }

    private static func localFallbackLines(records: [Record], now: Date) -> [MetricLine] {
        guard let currentBlock = billingBlock(containing: now, records: records) else { return [] }
        let progress = min(100, max(0, now.timeIntervalSince(currentBlock.start) / currentBlock.end.timeIntervalSince(currentBlock.start) * 100))
        return [MetricLine(label: "Session (local estimate)", used: progress, limit: 100, format: .percent, resetText: "Ends in \(duration(from: now, to: currentBlock.end))")]
    }

    private static func textLine(_ label: String, _ aggregate: Aggregate) -> MetricLine {
        MetricLine(label: label, used: 0, limit: 1, format: .text, resetText: nil, valueOverride: "$\(money(aggregate.cost)) · \(tokens(aggregate.tokens)) tokens")
    }

    private static func jsonlFiles(in directory: String) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: directory) else { return [] }
        return enumerator.compactMap { item -> String? in
            guard let relative = item as? String, relative.hasSuffix(".jsonl") else { return nil }
            return (directory as NSString).appendingPathComponent(relative)
        }
    }

    private static func parseRecords(path: String) -> [Record] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line -> Record? in
            guard let data = String(line).data(using: .utf8), let entry = try? JSONDecoder().decode(JSONLEntry.self, from: data), let timestamp = parseDate(entry.timestamp), let usage = entry.message?.usage else { return nil }
            let requestID = entry.requestId ?? entry.requestID
            let dedup = entry.message?.id.map { messageID in requestID.map { "\(messageID):\($0)" } ?? messageID }
            return Record(timestamp: timestamp, model: entry.message?.model ?? "", usage: usage, dedupKey: dedup)
        }
    }

    private static func aggregate(_ records: [Record]) -> Aggregate {
        records.reduce(Aggregate()) { partial, record in
            var next = partial
            next.input += record.usage.inputTokens; next.output += record.usage.outputTokens; next.cacheRead += record.usage.cacheReadInputTokens; next.cacheCreate += record.usage.cacheCreationInputTokens; next.messages += 1; next.cost += cost(record)
            return next
        }
    }

    private static func billingBlock(containing now: Date, records: [Record]) -> (start: Date, end: Date)? {
        var start: Date?; var end: Date?; var previous: Date?
        for record in records {
            if end == nil || record.timestamp >= end! || previous.map({ record.timestamp.timeIntervalSince($0) >= 5 * 60 * 60 }) == true {
                start = floorToHour(record.timestamp); end = start!.addingTimeInterval(5 * 60 * 60)
            }
            previous = record.timestamp
        }
        guard let start, let end, now >= start, now < end else { return nil }
        return (start, end)
    }

    private static func cost(_ record: Record) -> Double {
        let rates = rates(for: record.model)
        return Double(record.usage.inputTokens) / 1_000_000 * rates.input + Double(record.usage.outputTokens) / 1_000_000 * rates.output + Double(record.usage.cacheReadInputTokens) / 1_000_000 * rates.cacheRead + Double(record.usage.cacheCreationInputTokens) / 1_000_000 * rates.cacheCreate
    }

    private static func rates(for model: String) -> (input: Double, output: Double, cacheRead: Double, cacheCreate: Double) {
        let lower = model.lowercased()
        if lower.contains("fable") || lower.contains("claude-fable-5") { return (10, 50, 1, 12.5) }
        if lower.contains("opus-4-1") || lower.contains("opus-4.1") || (lower.contains("opus") && !lower.contains("4-5") && !lower.contains("4.5") && !lower.contains("4-6") && !lower.contains("4.6") && !lower.contains("4-7") && !lower.contains("4.7") && !lower.contains("4-8") && !lower.contains("4.8")) { return (15, 75, 1.5, 18.75) }
        if lower.contains("opus") { return (5, 25, 0.5, 6.25) }
        if lower.contains("haiku-3-5") || lower.contains("haiku-3.5") { return (0.8, 4, 0.08, 1) }
        if lower.contains("haiku") { return (1, 5, 0.1, 1.25) }
        return (3, 15, 0.3, 3.75)
    }

    private static func planLabel(credentials: ClaudeOAuthCredentials) -> String {
        if let tier = credentials.rateLimitTier, let match = tier.range(of: #"\d+x"#, options: .regularExpression) { return "Max \(tier[match])" }
        return credentials.subscriptionType?.isEmpty == false ? credentials.subscriptionType!.capitalized : "Claude Code"
    }

    private static func floorToHour(_ date: Date) -> Date { Calendar.current.dateInterval(of: .hour, for: date)?.start ?? date }
    private static func parseDate(_ value: String?) -> Date? { guard let value else { return nil }; return ISO8601DateFormatter.withFractions.date(from: value) ?? ISO8601DateFormatter.withoutFractions.date(from: value) }
    private static func money(_ value: Double) -> String { String(format: "%.2f", value) }
    private static func tokens(_ value: Int) -> String { let v = Double(value); if v >= 1_000_000_000 { return String(format: "%.1fB", v / 1_000_000_000) }; if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }; if v >= 1_000 { return String(format: "%.1fK", v / 1_000) }; return "\(value)" }
    private static func duration(from start: Date, to end: Date) -> String { let s = max(0, Int(end.timeIntervalSince(start))); let h = s / 3600; let m = (s % 3600) / 60; return h > 0 ? "\(h)h \(m)m" : "\(m)m" }

    private struct Record { let timestamp: Date; let model: String; let usage: JSONLUsage; let dedupKey: String?; var hasUsage: Bool { usage.inputTokens + usage.outputTokens + usage.cacheReadInputTokens + usage.cacheCreationInputTokens > 0 } }
    private struct Aggregate { var input = 0; var output = 0; var cacheRead = 0; var cacheCreate = 0; var messages = 0; var cost = 0.0; var tokens: Int { input + output + cacheRead + cacheCreate } }
    private struct JSONLEntry: Decodable { let timestamp: String?; let sessionId: String?; let requestId: String?; let requestID: String?; let message: JSONLMessage? }
    private struct JSONLMessage: Decodable { let id: String?; let model: String?; let usage: JSONLUsage? }
    private struct JSONLUsage: Decodable { let inputTokens: Int; let outputTokens: Int; let cacheReadInputTokens: Int; let cacheCreationInputTokens: Int; enum CodingKeys: String, CodingKey { case inputTokens = "input_tokens", outputTokens = "output_tokens", cacheReadInputTokens = "cache_read_input_tokens", cacheCreationInputTokens = "cache_creation_input_tokens" }; init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0; outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0; cacheReadInputTokens = try c.decodeIfPresent(Int.self, forKey: .cacheReadInputTokens) ?? 0; cacheCreationInputTokens = try c.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens) ?? 0 } }
}

private extension ISO8601DateFormatter {
    static let withFractions: ISO8601DateFormatter = { let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return formatter }()
    static let withoutFractions: ISO8601DateFormatter = { let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime]; return formatter }()
}
