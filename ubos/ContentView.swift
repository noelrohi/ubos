//
//  ContentView.swift
//  ubos
//
//  Created by Noel Rohi on 6/5/26.
//

import SwiftUI

struct ContentView: View {
    private let popoverWidth: CGFloat = 360

    @AppStorage(AppPreferences.refreshIntervalMinutesKey) private var refreshIntervalMinutes = 15
    @AppStorage(AppPreferences.openCodeGoEnabledKey) private var openCodeGoEnabled = true
    @AppStorage(AppPreferences.cursorEnabledKey) private var cursorEnabled = true
    @AppStorage(AppPreferences.codexEnabledKey) private var codexEnabled = true
    @AppStorage(AppPreferences.claudeCodeEnabledKey) private var claudeCodeEnabled = true

    @State private var providers = UsageSnapshot.initial
    @State private var lastRefresh = Date()
    @State private var nextRefresh = Date().addingTimeInterval(15 * 60)
    @State private var isRefreshing = false
    @State private var selectedProviderID = CodexUsageProvider.id
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                header

                ScrollView(.vertical) {
                    if let selectedProvider {
                        ProviderDetailView(
                            snapshot: selectedProvider,
                            isRefreshing: isRefreshing,
                            usageURL: usageURL(for: selectedProvider.id)
                        ) {
                            await refreshProvider(selectedProvider.id)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                .scrollIndicators(.visible)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                footer
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(width: popoverWidth, height: 420, alignment: .topLeading)
        .background(.regularMaterial)
        .animation(nil, value: isRefreshing)
        .animation(nil, value: providers.map(\.id))
        .task {
            selectFirstVisibleProviderIfNeeded()
            startAutoRefreshLoop()
            await refreshAfterPopoverAppears()
        }
        .onDisappear {
            refreshTask?.cancel()
            refreshTask = nil
        }
        .onChange(of: refreshIntervalMinutes) { _, _ in
            startAutoRefreshLoop()
        }
        .onChange(of: openCodeGoEnabled) { _, isEnabled in
            selectFirstVisibleProviderIfNeeded()
            if isEnabled { Task { await refreshProvider(OpenCodeGoUsageProvider.id) } }
        }
        .onChange(of: cursorEnabled) { _, isEnabled in
            selectFirstVisibleProviderIfNeeded()
            if isEnabled { Task { await refreshProvider(CursorUsageProvider.id) } }
        }
        .onChange(of: codexEnabled) { _, isEnabled in
            selectFirstVisibleProviderIfNeeded()
            if isEnabled { Task { await refreshProvider(CodexUsageProvider.id) } }
        }
        .onChange(of: claudeCodeEnabled) { _, isEnabled in
            selectFirstVisibleProviderIfNeeded()
            if isEnabled { Task { await refreshProvider(ClaudeCodeUsageProvider.id) } }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 10) {
            ForEach(visibleProviders) { provider in
                SidebarProviderButton(snapshot: provider, isSelected: provider.id == selectedProviderID) {
                    selectedProviderID = provider.id
                }
            }

            Spacer()
        }
        .padding(.vertical, 14)
        .frame(width: 54)
    }

    private var visibleProviders: [UsageSnapshot] {
        providers.filter { isProviderVisible($0.id) }
    }

    private var selectedProvider: UsageSnapshot? {
        visibleProviders.first { $0.id == selectedProviderID } ?? visibleProviders.first
    }

    private func isProviderVisible(_ id: String) -> Bool {
        switch id {
        case OpenCodeGoUsageProvider.id:
            openCodeGoEnabled
        case CursorUsageProvider.id:
            cursorEnabled
        case CodexUsageProvider.id:
            codexEnabled
        case ClaudeCodeUsageProvider.id:
            claudeCodeEnabled
        default:
            true
        }
    }

    private func selectFirstVisibleProviderIfNeeded() {
        guard !isProviderVisible(selectedProviderID) else { return }
        if let firstVisible = visibleProviders.first {
            selectedProviderID = firstVisible.id
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedProvider?.name ?? "Ubos")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(selectedProvider?.plan ?? "AI subscription usage")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(lastRefresh, style: .time)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(isRefreshing ? "Refreshing now" : "Next refresh \(nextRefresh, style: .relative)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .monospacedDigit()
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                Task {
                    if let selectedProvider {
                        await refreshProvider(selectedProvider.id)
                    } else {
                        await refreshData()
                    }
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(isRefreshing)
            .controlSize(.small)

            Button {
                SettingsWindowController.show()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }

    private func usageURL(for providerID: String) -> URL? {
        switch providerID {
        case ClaudeCodeUsageProvider.id:
            return URL(string: "https://claude.ai/settings/usage")
        case CursorUsageProvider.id:
            return URL(string: "https://cursor.com/dashboard")
        case CodexUsageProvider.id:
            return URL(string: "https://chatgpt.com/#settings/Subscription")
        case OpenCodeGoUsageProvider.id:
            return URL(string: "https://opencode.ai/billing")
        default:
            return nil
        }
    }

    private func refreshData() async {
        guard !isRefreshing else { return }

        isRefreshing = true
        lastRefresh = Date()

        defer {
            isRefreshing = false
        }

        async let cursorSnapshot = CursorUsageProvider.loadSnapshot()
        async let codexSnapshot = CodexUsageProvider.loadSnapshot()
        let opencodeSnapshot = OpenCodeGoUsageProvider.loadSnapshot()
        async let claudeSnapshot = ClaudeCodeUsageProvider.loadSnapshot()
        let updates = await [
            opencodeSnapshot,
            cursorSnapshot,
            codexSnapshot,
            claudeSnapshot
        ]

        providers = providers.map { snapshot in
            guard let update = updates.first(where: { $0.id == snapshot.id }) else { return snapshot }
            return mergedSnapshot(current: snapshot, update: update)
        }
    }

    private func refreshAfterPopoverAppears() async {
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return }
        await refreshData()
    }

    private func refreshProvider(_ id: String) async {
        let snapshot: UsageSnapshot
        switch id {
        case OpenCodeGoUsageProvider.id:
            snapshot = OpenCodeGoUsageProvider.loadSnapshot()
        case CursorUsageProvider.id:
            snapshot = await CursorUsageProvider.loadSnapshot()
        case CodexUsageProvider.id:
            snapshot = await CodexUsageProvider.loadSnapshot()
        case ClaudeCodeUsageProvider.id:
            snapshot = await ClaudeCodeUsageProvider.loadSnapshot()
        default:
            return
        }

        providers = providers.map { current in
            current.id == id ? mergedSnapshot(current: current, update: snapshot) : current
        }
        lastRefresh = Date()
    }

    private func mergedSnapshot(current: UsageSnapshot, update: UsageSnapshot) -> UsageSnapshot {
        guard update.isTransientFailure, current.hasUsageData else { return update }
        return current.withRefreshFailure(message: update.message)
    }

    private func startAutoRefreshLoop() {
        refreshTask?.cancel()
        let minutes = max(1, refreshIntervalMinutes)
        let intervalSeconds = minutes * 60
        nextRefresh = Date().addingTimeInterval(TimeInterval(intervalSeconds))
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(intervalSeconds))
                guard !Task.isCancelled else { return }
                await refreshData()
                nextRefresh = Date().addingTimeInterval(TimeInterval(intervalSeconds))
            }
        }
    }
}

struct SidebarProviderButton: View {
    let snapshot: UsageSnapshot
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            BrandIconView(snapshot: snapshot)
                .frame(width: 26, height: 26)
                .padding(6)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
                }
                .overlay(alignment: .leading) {
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(Color.accentColor)
                            .frame(width: 3, height: 18)
                            .offset(x: -8)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(snapshot.name)
    }
}

struct ProviderDetailView: View {
    let snapshot: UsageSnapshot
    let isRefreshing: Bool
    let usageURL: URL?
    let retry: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if snapshot.status == "loading", !snapshot.hasUsageData {
                ProviderDetailSkeletonView()
            } else {
                if let message = snapshot.message, !snapshot.hasUsageData {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)

                        Spacer()

                        if snapshot.canRetry {
                            Button("Retry") {
                                Task { await retry() }
                            }
                            .buttonStyle(.borderless)
                            .font(.caption2.weight(.semibold))
                        }
                    }
                }

                if snapshot.hasUsageData {
                    VStack(alignment: .leading, spacing: 14) {
                        if let usageURL {
                            Link(destination: usageURL) {
                                Label("Open usage page", systemImage: "arrow.up.right.square")
                                    .font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(.blue)
                        }

                        ForEach(visibleLines) { line in
                            MetricLineView(line: line, color: snapshot.color)
                        }
                    }
                    .opacity(isRefreshing ? 0.55 : 1)
                }
            }
        }
    }

    private var visibleLines: [MetricLine] {
        snapshot.lines.filter { line in
            line.label != "Requests" && line.label != "Reviews"
        }
    }
}

struct ProviderDetailSkeletonView: View {
    var body: some View {
        VStack(spacing: 14) {
            ForEach(0..<3, id: \.self) { index in
                VStack(alignment: .leading, spacing: 8) {
                    skeletonBar(width: index == 1 ? 92 : 120, height: 18)

                    skeletonBar(width: nil, height: 14)

                    HStack {
                        skeletonBar(width: index == 2 ? 86 : 118, height: 14)

                        Spacer(minLength: 12)

                        skeletonBar(width: index == 0 ? 112 : 76, height: 14)
                    }
                }
            }
        }
        .redacted(reason: .placeholder)
        .accessibilityLabel("Loading usage data")
    }

    private func skeletonBar(width: CGFloat?, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.28))
            .frame(width: width, height: height)
    }
}

struct BrandIconView: View {
    let snapshot: UsageSnapshot

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary)

            if let iconName = snapshot.iconName {
                Image(iconName)
                    .resizable()
                    .scaledToFit()
                    .padding(iconPadding)
            } else {
                Text(snapshot.shortName)
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var iconPadding: CGFloat {
        switch snapshot.id {
        case OpenCodeGoUsageProvider.id:
            0
        default:
            4
        }
    }
}

struct MetricLineView: View {
    @AppStorage(AppPreferences.usageDisplayModeKey) private var usageDisplayMode = UsageDisplayMode.used.rawValue

    let line: MetricLine
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(line.label)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)

            if line.showsProgress {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.18))

                        Capsule(style: .continuous)
                            .fill(progressFill)
                            .frame(width: max(0, min(proxy.size.width, proxy.size.width * progressFraction)))
                    }
                }
                .frame(height: 14)
                .help(helpText)
            }

            HStack(alignment: .firstTextBaseline) {
                Text(displayedValueText)
                    .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 12)

                if let resetText = line.resetText, !resetText.isEmpty {
                    Text(resetText)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .help(helpText)
    }

    private var mode: UsageDisplayMode {
        UsageDisplayMode(rawValue: usageDisplayMode) ?? .remaining
    }

    private var displayedValue: Double {
        switch mode {
        case .used:
            return line.used
        case .remaining:
            return max(0, line.limit - line.used)
        }
    }

    private var progressFraction: CGFloat {
        guard line.limit > 0 else { return 0 }
        return CGFloat(min(1, max(0, displayedValue / line.limit)))
    }

    private var progressFill: Color {
        Color(nsColor: .controlAccentColor)
    }

    private var displayedValueText: String {
        switch mode {
        case .used:
            return line.valueText
        case .remaining:
            return line.valueText(for: displayedValue)
        }
    }

    private var helpText: String {
        let prefix = mode == .remaining ? "Showing remaining." : "Showing used."
        guard let resetText = line.resetText, !resetText.isEmpty else { return prefix }
        return "\(prefix) \(resetText)"
    }
}

enum UsageDisplayMode: String, CaseIterable, Identifiable {
    case remaining
    case used

    var id: Self { self }

    var title: String {
        switch self {
        case .remaining: "Remaining"
        case .used: "Used"
        }
    }
}

struct UsageSnapshot: Identifiable {
    let id: String
    let name: String
    let shortName: String
    let plan: String
    let status: String
    let statusColor: Color
    let color: Color
    let iconName: String?
    let lines: [MetricLine]
    let message: String?

    init(
        id: String,
        name: String,
        shortName: String,
        plan: String,
        status: String,
        statusColor: Color,
        color: Color,
        iconName: String? = nil,
        lines: [MetricLine],
        message: String? = nil
    ) {
        self.id = id
        self.name = name
        self.shortName = shortName
        self.plan = plan
        self.status = status
        self.statusColor = statusColor
        self.color = color
        self.iconName = iconName
        self.lines = lines
        self.message = message
    }

    var canRetry: Bool {
        switch status {
        case "error", "expired", "missing", "no data":
            true
        default:
            false
        }
    }

    var hasUsageData: Bool {
        lines.contains { $0.format != .text || ($0.format == .text && $0.label != "Status") }
    }

    var isTransientFailure: Bool {
        status == "error"
    }

    func withRefreshFailure(message: String?) -> UsageSnapshot {
        UsageSnapshot(
            id: id,
            name: name,
            shortName: shortName,
            plan: plan,
            status: "error",
            statusColor: .red,
            color: color,
            iconName: iconName,
            lines: lines,
            message: message ?? "Refresh failed. Showing the last successful snapshot."
        )
    }

    static let initial: [UsageSnapshot] = [
        UsageSnapshot(
            id: "claude-code",
            name: "Claude Code",
            shortName: "CC",
            plan: "Claude Code",
            status: "loading",
            statusColor: .secondary,
            color: Color(red: 0.86, green: 0.45, blue: 0.25),
            iconName: "ClaudeIcon",
            lines: [
                MetricLine(label: "Status", used: 0, limit: 1, format: .text, resetText: "Waiting for first Claude Code refresh.", valueOverride: "loading")
            ],
            message: "Waiting for first Claude Code refresh."
        ),
        UsageSnapshot(
            id: "codex",
            name: "Codex",
            shortName: "CX",
            plan: "Codex",
            status: "loading",
            statusColor: .secondary,
            color: Color(red: 0.45, green: 0.67, blue: 0.61),
            iconName: "OpenAIIcon",
            lines: [
                MetricLine(label: "Status", used: 0, limit: 1, format: .text, resetText: "Waiting for first Codex refresh.", valueOverride: "loading")
            ],
            message: "Waiting for first Codex refresh."
        ),
        UsageSnapshot(
            id: "cursor",
            name: "Cursor",
            shortName: "CU",
            plan: "Cursor",
            status: "loading",
            statusColor: .secondary,
            color: .blue,
            iconName: "CursorIcon",
            lines: [
                MetricLine(label: "Status", used: 0, limit: 1, format: .text, resetText: "Waiting for first Cursor refresh.", valueOverride: "loading")
            ],
            message: "Waiting for first Cursor refresh."
        ),
        UsageSnapshot(
            id: "opencode-go",
            name: "OpenCode Go",
            shortName: "OG",
            plan: "Go",
            status: "loading",
            statusColor: .secondary,
            color: .black,
            iconName: "OpenCodeIcon",
            lines: [
                MetricLine(label: "Status", used: 0, limit: 1, format: .text, resetText: "Waiting for first OpenCode Go refresh.", valueOverride: "loading")
            ],
            message: "Waiting for first OpenCode Go refresh."
        )
    ]
}

struct MetricLine: Identifiable {
    enum Format: Equatable {
        case percent
        case dollars
        case count(String)
        case text
    }

    let id = UUID()
    let label: String
    let used: Double
    let limit: Double
    let format: Format
    let resetText: String?
    let valueOverride: String?

    init(label: String, used: Double, limit: Double, format: Format, resetText: String?, valueOverride: String? = nil) {
        self.label = label
        self.used = used
        self.limit = limit
        self.format = format
        self.resetText = resetText
        self.valueOverride = valueOverride
    }

    var showsProgress: Bool {
        switch format {
        case .text:
            return false
        case .percent, .dollars, .count:
            return true
        }
    }

    var valueText: String {
        if let valueOverride {
            return valueOverride
        }

        return valueText(for: used)
    }

    func valueText(for value: Double) -> String {
        if format == .text, let valueOverride {
            return valueOverride
        }

        switch format {
        case .percent:
            if value > 0, value < 10 {
                let rounded = (value * 10).rounded() / 10
                if rounded == rounded.rounded() {
                    return "\(Int(rounded))%"
                }
                return "\(String(format: "%.1f", rounded))%"
            }
            return "\(Int(value.rounded()))%"
        case .dollars:
            return "$\(Int(value.rounded())) / $\(Int(limit.rounded()))"
        case .count(let suffix):
            return "\(Int(value.rounded())) / \(Int(limit.rounded())) \(suffix)"
        case .text:
            return ""
        }
    }
}

#Preview {
    ContentView()
}
