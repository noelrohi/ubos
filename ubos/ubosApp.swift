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

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        popover = NSPopover()

        super.init()

        configureStatusItem()
        configurePopover()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }

        let image = Self.makeMenuBarIcon()
        image.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly

        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
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
