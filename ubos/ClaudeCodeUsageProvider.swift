import Foundation
import SwiftUI

enum ClaudeCodeUsageProvider {
    static let id = "claude-code"

    static func loadSnapshot() -> UsageSnapshot {
        guard AppPreferences.isProviderEnabled(AppPreferences.claudeCodeEnabledKey) else {
            return snapshot(status: "disabled", statusColor: .secondary, lines: [
                MetricLine(label: "Status", used: 0, limit: 1, format: .text, resetText: "Enable Claude Code in Settings.", valueOverride: "disabled")
            ], message: "Claude Code usage is disabled.")
        }

        let projectsDirs = [
            UserHome.expand("~/.claude/projects"),
            UserHome.expand("~/.config/claude/projects")
        ]

        let files = projectsDirs.flatMap { jsonlFiles(in: $0) }
        guard !files.isEmpty else {
            return snapshot(status: "missing", statusColor: .orange, lines: [
                MetricLine(label: "Status", used: 0, limit: 1, format: .text, resetText: "No Claude Code JSONL transcripts found.", valueOverride: "missing")
            ], message: "Run Claude Code once, then allow ubos to read ~/.claude/projects.")
        }

        var records: [Record] = []
        for file in files {
            records.append(contentsOf: parseRecords(path: file))
        }
        records.sort { $0.timestamp < $1.timestamp }
        let usageRecords = records.filter { $0.hasUsage }
        guard !usageRecords.isEmpty else {
            return snapshot(status: "no data", statusColor: .orange, lines: [
                MetricLine(label: "Status", used: 0, limit: 1, format: .text, resetText: "Transcripts found, but no token usage entries were readable.", valueOverride: "no usage")
            ], message: "Claude Code transcripts were found, but no token usage entries were readable.")
        }

        let now = Date()
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let weekStart = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let currentBlock = billingBlock(containing: now, records: usageRecords)

        let today = aggregate(usageRecords.filter { $0.timestamp >= todayStart })
        let weekly = aggregate(usageRecords.filter { $0.timestamp >= weekStart })
        let block = currentBlock.map { window in
            aggregate(usageRecords.filter { record in
                record.timestamp >= window.start && record.timestamp < window.end
            })
        }

        let blockProgress: Double
        let blockReset: String
        if let currentBlock {
            blockProgress = min(100, max(0, now.timeIntervalSince(currentBlock.start) / currentBlock.end.timeIntervalSince(currentBlock.start) * 100))
            blockReset = "resets \(relative(currentBlock.end)) · \(block?.messages ?? 0) msgs"
        } else {
            blockProgress = 0
            blockReset = "no active 5h block"
        }

        let lines = [
            MetricLine(label: "5h Block", used: blockProgress, limit: 100, format: .percent, resetText: blockReset),
            MetricLine(label: "Today Tokens", used: Double(today.tokens), limit: max(200_000, Double(today.tokens)), format: .count("tokens"), resetText: "$\(money(today.cost)) API-est · \(today.messages) msgs"),
            MetricLine(label: "Weekly Tokens", used: Double(weekly.tokens), limit: max(1_000_000, Double(weekly.tokens)), format: .count("tokens"), resetText: "$\(money(weekly.cost)) API-est · 7d local")
        ]

        return snapshot(
            status: "ok",
            statusColor: .green,
            lines: lines,
            message: "Local Claude Code usage. Costs are API-equivalent estimates, not subscription charges."
        )
    }

    private static func snapshot(status: String, statusColor: Color, lines: [MetricLine], message: String?) -> UsageSnapshot {
        UsageSnapshot(
            id: id,
            name: "Claude Code",
            shortName: "CC",
            plan: "Claude Code",
            status: status,
            statusColor: statusColor,
            color: Color(red: 0.86, green: 0.45, blue: 0.25),
            lines: lines,
            message: message
        )
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
        return text.split(separator: "\n").compactMap { line in
            guard let data = String(line).data(using: .utf8),
                  let entry = try? JSONDecoder().decode(JSONLEntry.self, from: data),
                  let timestamp = parseDate(entry.timestamp),
                  let usage = entry.message?.usage else { return nil }
            return Record(timestamp: timestamp, sessionID: entry.sessionId ?? "", model: entry.message?.model ?? "", usage: usage)
        }
    }

    private static func aggregate(_ records: [Record]) -> Aggregate {
        records.reduce(Aggregate()) { partial, record in
            var next = partial
            next.input += record.usage.inputTokens
            next.output += record.usage.outputTokens
            next.cacheRead += record.usage.cacheReadInputTokens
            next.cacheCreate += record.usage.cacheCreationInputTokens
            next.messages += 1
            next.cost += cost(record)
            return next
        }
    }

    private static func billingBlock(containing now: Date, records: [Record]) -> (start: Date, end: Date)? {
        var start: Date?
        var end: Date?
        for record in records {
            if end == nil || record.timestamp >= end! {
                start = floorToHour(record.timestamp)
                end = start!.addingTimeInterval(5 * 60 * 60)
            }
        }
        guard let start, let end, now >= start, now < end else { return nil }
        return (start, end)
    }

    private static func cost(_ record: Record) -> Double {
        let rates = rates(for: record.model)
        return Double(record.usage.inputTokens) / 1_000_000 * rates.input
            + Double(record.usage.outputTokens) / 1_000_000 * rates.output
            + Double(record.usage.cacheReadInputTokens) / 1_000_000 * rates.cacheRead
            + Double(record.usage.cacheCreationInputTokens) / 1_000_000 * rates.cacheCreate
    }

    private static func rates(for model: String) -> (input: Double, output: Double, cacheRead: Double, cacheCreate: Double) {
        let lower = model.lowercased()
        if lower.contains("opus") { return (15, 75, 1.5, 18.75) }
        if lower.contains("haiku") { return (0.8, 4, 0.08, 1) }
        return (3, 15, 0.3, 3.75)
    }

    private static func floorToHour(_ date: Date) -> Date {
        Calendar.current.dateInterval(of: .hour, for: date)?.start ?? date
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        if let date = ISO8601DateFormatter.withFractions.date(from: value) { return date }
        return ISO8601DateFormatter.withoutFractions.date(from: value)
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private static func money(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private struct Record {
        let timestamp: Date
        let sessionID: String
        let model: String
        let usage: JSONLUsage
        var hasUsage: Bool { usage.inputTokens + usage.outputTokens + usage.cacheReadInputTokens + usage.cacheCreationInputTokens > 0 }
    }

    private struct Aggregate {
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheCreate = 0
        var messages = 0
        var cost = 0.0
        var tokens: Int { input + output + cacheRead + cacheCreate }
    }

    private struct JSONLEntry: Decodable {
        let timestamp: String?
        let sessionId: String?
        let message: JSONLMessage?
    }

    private struct JSONLMessage: Decodable {
        let model: String?
        let usage: JSONLUsage?
    }

    private struct JSONLUsage: Decodable {
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadInputTokens: Int
        let cacheCreationInputTokens: Int

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
            outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
            cacheReadInputTokens = try container.decodeIfPresent(Int.self, forKey: .cacheReadInputTokens) ?? 0
            cacheCreationInputTokens = try container.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens) ?? 0
        }
    }
}

private extension ISO8601DateFormatter {
    static let withFractions: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let withoutFractions: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
