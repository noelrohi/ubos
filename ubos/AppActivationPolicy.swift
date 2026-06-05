import AppKit

@MainActor
enum AppActivationPolicy {
    private static var foregroundWindowCount = 0

    static func configureMenuBarOnly() {
        guard !isRunningUnderXCTest else { return }
        guard foregroundWindowCount == 0 else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    static func enterForegroundWindow() {
        guard !isRunningUnderXCTest else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        foregroundWindowCount += 1
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func leaveForegroundWindow() {
        guard !isRunningUnderXCTest else { return }

        foregroundWindowCount = max(0, foregroundWindowCount - 1)
        guard foregroundWindowCount == 0 else { return }

        Task { @MainActor in
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
