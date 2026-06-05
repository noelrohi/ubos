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
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppActivationPolicy.configureMenuBarOnly()
        statusBarController = StatusBarController()
    }
}

private final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let popoverSize = NSSize(width: 388, height: 420)

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        popover = NSPopover()

        super.init()

        configureStatusItem()
        configurePopover()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }

        if let image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "ubos") {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
        } else {
            button.title = "ubos"
        }

        button.target = self
        button.action = #selector(togglePopover(_:))
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

        popover.contentSize = popoverSize
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentSize = popoverSize
    }
}
