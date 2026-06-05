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

    @State private var providers = UsageSnapshot.initial
    @State private var lastRefresh = Date()
    @State private var isRefreshing = false
    @State private var selectedProviderID = CodexUsageProvider.id
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                header

                if let selectedProvider {
                    ProviderDetailView(snapshot: selectedProvider, isRefreshing: isRefreshing) {
                        await refreshProvider(selectedProvider.id)
                    }
                }

                Spacer(minLength: 0)

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
        .onChange(of: openCodeGoEnabled) { _, _ in
            Task { await refreshProvider(OpenCodeGoUsageProvider.id) }
        }
        .onChange(of: cursorEnabled) { _, _ in
            Task { await refreshProvider(CursorUsageProvider.id) }
        }
        .onChange(of: codexEnabled) { _, _ in
            Task { await refreshProvider(CodexUsageProvider.id) }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 10) {
            ForEach(providers) { provider in
                SidebarProviderButton(snapshot: provider, isSelected: provider.id == selectedProviderID) {
                    selectedProviderID = provider.id
                }
            }

            Spacer()
        }
        .padding(.vertical, 14)
        .frame(width: 54)
    }

    private var selectedProvider: UsageSnapshot? {
        providers.first { $0.id == selectedProviderID } ?? providers.first
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

            Text(lastRefresh, style: .time)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
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
        let updates = await [
            opencodeSnapshot,
            cursorSnapshot,
            codexSnapshot
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
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(minutes * 60))
                guard !Task.isCancelled else { return }
                await refreshData()
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
    let retry: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let message = snapshot.message, !snapshot.hasUsageData, snapshot.status != "loading" {
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
                VStack(spacing: 14) {
                    ForEach(visibleLines) { line in
                        MetricLineView(line: line, color: snapshot.color)
                    }
                }
                .opacity(isRefreshing ? 0.55 : 1)
            }
        }
    }

    private var visibleLines: [MetricLine] {
        snapshot.lines.filter { line in
            line.label != "Requests" && line.label != "Reviews"
        }
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
    @AppStorage(AppPreferences.usageDisplayModeKey) private var usageDisplayMode = UsageDisplayMode.remaining.rawValue

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
            line.used
        case .remaining:
            max(0, line.limit - line.used)
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
        lines.contains { $0.format != .text }
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
