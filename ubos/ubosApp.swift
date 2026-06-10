//
//  ubosApp.swift
//  ubos
//
//  Created by Noel Rohi on 6/5/26.
//

import SwiftUI
import AppKit

@main
struct ubosApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let updaterManager = UpdaterManager.shared
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppActivationPolicy.configureMenuBarOnly()
        statusBarController = StatusBarController()
        updaterManager.start()
    }
}

private final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let popoverSize = NSSize(width: 360, height: 420)
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var selectedSnapshot: UsageSnapshot?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        popover = NSPopover()

        super.init()

        configureStatusItem()
        configurePopover()
        observeMenuBarUpdates()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }

        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        updateStatusItemDisplay()
    }

    private func observeMenuBarUpdates() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(selectedSnapshotDidChange(_:)),
            name: .ubosSelectedUsageSnapshotDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(defaultsDidChange(_:)),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    @objc private func selectedSnapshotDidChange(_ notification: Notification) {
        selectedSnapshot = notification.object as? UsageSnapshot
        updateStatusItemDisplay()
    }

    @objc private func defaultsDidChange(_ notification: Notification) {
        updateStatusItemDisplay()
    }

    private func updateStatusItemDisplay() {
        guard let button = statusItem.button else { return }
        let style = MenuBarDisplayStyle(rawValue: UserDefaults.standard.string(forKey: AppPreferences.menuBarDisplayStyleKey) ?? "") ?? .icon

        switch style {
        case .icon:
            statusItem.length = NSStatusItem.squareLength
            let image = Self.makeMenuBarIcon()
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.title = ""
        case .percentage:
            statusItem.length = NSStatusItem.variableLength
            let image = menuBarProviderIcon() ?? Self.makeMenuBarIcon()
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeft
            button.title = " " + menuBarPercentageText()
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        }
    }

    private func menuBarPercentageText() -> String {
        guard let line = selectedSnapshot?.lines.first(where: { $0.showsProgress }) else { return "--%" }
        let displayMode = UsageDisplayMode(rawValue: UserDefaults.standard.string(forKey: AppPreferences.usageDisplayModeKey) ?? "") ?? .used
        let value: Double
        switch displayMode {
        case .used:
            value = line.used
        case .remaining:
            value = max(0, line.limit - line.used)
        }
        return Self.percentText(value)
    }

    private func menuBarProviderIcon() -> NSImage? {
        guard let iconName = selectedSnapshot?.iconName,
              let image = NSImage(named: iconName) else { return nil }
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    private static func percentText(_ value: Double) -> String {
        if value > 0, value < 10 {
            let rounded = (value * 10).rounded() / 10
            if rounded == rounded.rounded() { return "\(Int(rounded))%" }
            return "\(String(format: "%.1f", rounded))%"
        }
        return "\(Int(value.rounded()))%"
    }

    private static func makeMenuBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)

        image.lockFocus()
        NSColor.black.setStroke()
        NSColor.black.setFill()

        let path = NSBezierPath()
        path.lineWidth = 2.4
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: NSPoint(x: 4.5, y: 12.7))
        path.line(to: NSPoint(x: 4.5, y: 7.0))
        path.curve(
            to: NSPoint(x: 13.5, y: 7.0),
            controlPoint1: NSPoint(x: 4.5, y: 2.9),
            controlPoint2: NSPoint(x: 13.5, y: 2.9)
        )
        path.line(to: NSPoint(x: 13.5, y: 12.7))
        path.stroke()

        NSBezierPath(ovalIn: NSRect(x: 10.1, y: 6.1, width: 3.2, height: 3.2)).fill()
        image.unlockFocus()

        return image
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = popoverSize
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: ContentView())
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        popover.contentSize = popoverSize
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        startEventMonitor()
    }

    private func startEventMonitor() {
        guard globalEventMonitor == nil, localEventMonitor == nil else { return }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopoverForOutsideClick()
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.closePopoverForOutsideClick(event: event)
            return event
        }
    }

    private func closePopoverForOutsideClick(event: NSEvent? = nil) {
        guard popover.isShown else { return }

        if let event, event.window === popover.contentViewController?.view.window {
            return
        }

        if let button = statusItem.button, !button.isHidden {
            let clickLocation = NSEvent.mouseLocation
            let buttonFrame = button.window?.convertToScreen(button.frame) ?? .zero
            if buttonFrame.contains(clickLocation) {
                return
            }
        }

        popover.performClose(nil)
    }

    private func stopEventMonitor() {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }

        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
    }

    func popoverDidClose(_ notification: Notification) {
        stopEventMonitor()
        popover.contentSize = popoverSize
    }
}
