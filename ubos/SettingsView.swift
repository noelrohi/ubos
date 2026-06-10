import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case codex
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .codex: "Codex"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .codex: "terminal"
        case .about: "info.circle"
        }
    }
}

@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var selectedTab: SettingsTab? = .general
    private init() {}
}

struct SettingsView: View {
    @State private var navigation = SettingsNavigation.shared
    @State private var navigationHistory: [SettingsTab] = [.general]
    @State private var historyIndex = 0
    @State private var isHistoryNavigation = false

    private var activeTab: SettingsTab {
        navigation.selectedTab ?? .general
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SettingsSidebarView(selectedTab: $navigation.selectedTab)
                .navigationSplitViewColumnWidth(min: 200, ideal: 200, max: 220)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            SettingsDetailView(tab: activeTab)
        }
        .navigationTitle("Settings")
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 660, minHeight: 500)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    goBack()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!canGoBack)
                .help("Back")

                Button {
                    goForward()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!canGoForward)
                .help("Forward")
            }
        }
        .onChange(of: navigation.selectedTab) { _, _ in
            recordNavigation()
        }
    }

    private var canGoBack: Bool {
        historyIndex > 0
    }

    private var canGoForward: Bool {
        historyIndex < navigationHistory.count - 1
    }

    private func goBack() {
        guard canGoBack else { return }
        isHistoryNavigation = true
        historyIndex -= 1
        navigation.selectedTab = navigationHistory[historyIndex]
        DispatchQueue.main.async {
            isHistoryNavigation = false
        }
    }

    private func goForward() {
        guard canGoForward else { return }
        isHistoryNavigation = true
        historyIndex += 1
        navigation.selectedTab = navigationHistory[historyIndex]
        DispatchQueue.main.async {
            isHistoryNavigation = false
        }
    }

    private func recordNavigation() {
        guard !isHistoryNavigation, let tab = navigation.selectedTab else { return }
        if navigationHistory.last == tab { return }
        if historyIndex < navigationHistory.count - 1 {
            navigationHistory = Array(navigationHistory.prefix(historyIndex + 1))
        }
        navigationHistory.append(tab)
        historyIndex = navigationHistory.count - 1
    }
}

private struct SettingsSidebarView: View {
    @Binding var selectedTab: SettingsTab?

    var body: some View {
        List(selection: $selectedTab) {
            ForEach(SettingsTab.allCases) { tab in
                Label(tab.title, systemImage: tab.systemImage)
                    .tag(tab)
            }

            Text(AppVersion.displayString)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 6, trailing: 0))
        }
        .listStyle(.sidebar)
        .scrollEdgeEffectStyleSoftIfAvailable()
        .navigationTitle("Settings")
    }
}

private struct SettingsDetailView: View {
    let tab: SettingsTab

    var body: some View {
        Group {
            switch tab {
            case .general:
                GeneralSettingsPane()
            case .codex:
                CodexSettingsPane()
            case .about:
                AboutSettingsPane()
            }
        }
        .navigationTitle(tab.title)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private enum AppVersion {
    static let displayString: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(version) (\(build))"
    }()
}

private struct ProviderToggleRow: View {
    let title: String
    let description: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
    }
}

private struct GeneralSettingsPane: View {
    @AppStorage(AppPreferences.refreshIntervalMinutesKey) private var refreshIntervalMinutes = 15
    @AppStorage(AppPreferences.usageDisplayModeKey) private var usageDisplayMode = UsageDisplayMode.used.rawValue
    @AppStorage(AppPreferences.openCodeGoEnabledKey) private var openCodeGoEnabled = true
    @AppStorage(AppPreferences.cursorEnabledKey) private var cursorEnabled = true
    @AppStorage(AppPreferences.codexEnabledKey) private var codexEnabled = true
    @AppStorage(AppPreferences.claudeCodeEnabledKey) private var claudeCodeEnabled = true

    var body: some View {
        Form {
            Section("Providers") {
                ProviderToggleRow(
                    title: "OpenCode Go",
                    description: "Reads local observed spend from ~/.local/share/opencode.",
                    isOn: $openCodeGoEnabled
                )
                ProviderToggleRow(
                    title: "Cursor",
                    description: "Reads Cursor auth locally, then fetches usage from Cursor endpoints.",
                    isOn: $cursorEnabled
                )
                ProviderToggleRow(
                    title: "Codex",
                    description: "Reads Codex CLI OAuth credentials and WHAM usage.",
                    isOn: $codexEnabled
                )
                ProviderToggleRow(
                    title: "Claude Code",
                    description: "Reads local Claude Code JSONL transcripts from ~/.claude/projects.",
                    isOn: $claudeCodeEnabled
                )

                Text("Provider data stays local to this Mac. Ubos reads local app files, macOS Keychain entries, and provider usage APIs directly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Refresh") {
                Picker("Automatic refresh", selection: $refreshIntervalMinutes) {
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("60 minutes").tag(60)
                }
                .pickerStyle(.menu)

                Text("The menu bar popover refreshes providers on open, manual refresh, and this interval while visible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Display") {
                Picker("Usage display", selection: $usageDisplayMode) {
                    ForEach(UsageDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text("Used matches provider usage pages. Remaining flips quota rows into a battery-style view.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                LabeledContent("Storage", value: "UserDefaults for preferences, Keychain for token writes")
                LabeledContent("Network", value: "Provider APIs only")
                Text("Ubos does not run a local server or send provider data to a third-party analytics service.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}

private struct CodexSettingsPane: View {
    @AppStorage(AppPreferences.codexEnabledKey) private var codexEnabled = true

    private var authStatus: String {
        if FileManager.default.fileExists(atPath: UserHome.expand("~/.config/codex/auth.json")) {
            return "~/.config/codex/auth.json"
        }
        if FileManager.default.fileExists(atPath: UserHome.expand("~/.codex/auth.json")) {
            return "~/.codex/auth.json"
        }
        if KeychainStore.read(service: "Codex Auth") != nil {
            return "macOS Keychain: Codex Auth"
        }
        return "Not found"
    }

    var body: some View {
        Form {
            Section("Provider") {
                Toggle("Enable Codex", isOn: $codexEnabled)
                    .toggleStyle(.switch)

                LabeledContent("Auth source", value: authStatus)

                Text("Ubos reads the same Codex CLI OAuth credentials as OpenUsage. Run `codex` if authentication is missing or expired.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Usage API") {
                LabeledContent("Endpoint", value: "chatgpt.com/backend-api/wham/usage")
                LabeledContent("Metrics", value: "Session, Weekly, Reviews, Credits")

                Text("This is a reverse-engineered, undocumented Codex endpoint and may change without notice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}

private struct AboutSettingsPane: View {
    @ObservedObject private var updaterManager = UpdaterManager.shared

    var body: some View {
        Form {
            Section("Ubos") {
                LabeledContent("Version", value: AppVersion.displayString)
                LabeledContent("Providers", value: "OpenCode Go, Cursor, Codex, Claude Code")
            }

            Section("Updates") {
                Toggle(isOn: Binding(
                    get: { updaterManager.automaticallyChecksForUpdates },
                    set: { updaterManager.automaticallyChecksForUpdates = $0 }
                )) {
                    Text("Automatically check for updates")
                }
                .toggleStyle(.switch)

                Button("Check for Updates...") {
                    updaterManager.checkForUpdates()
                }
                .disabled(!updaterManager.canCheckForUpdates)

                Text("Updates are checked through the GitHub-hosted Sparkle appcast.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                LabeledContent("Codex auth", value: "~/.config/codex/auth.json or ~/.codex/auth.json")
                LabeledContent("OpenCode data", value: "~/.local/share/opencode/opencode.db")
                LabeledContent("Cursor data", value: "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}

private extension View {
    @ViewBuilder
    func scrollEdgeEffectStyleSoftIfAvailable() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            self
        }
    }
}
