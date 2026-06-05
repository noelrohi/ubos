# ubos

ubos is a native macOS menu bar app for checking AI subscription usage in one compact popover.

It currently tracks:

- Codex usage from local Codex auth and the ChatGPT usage endpoint
- Cursor plan usage, auto usage, credits, and on-demand spend
- OpenCode Go usage from the local OpenCode SQLite database

## App Shape

ubos is built as a SwiftUI macOS app with an AppKit menu bar controller:

- `NSStatusItem` owns the menu bar icon.
- `NSPopover` hosts the SwiftUI usage view.
- The app runs as a menu-bar-only accessory app.
- Settings use a native macOS preferences window.

The popover is intentionally dense: provider cards use brand icons, compact metric rows, status dots, and skeleton rows while usage is loading.

## Requirements

- macOS 26.2 or newer
- Xcode with the macOS 26.2 SDK
- Local sign-ins for the providers you want to track

Provider data is read from local app state:

- OpenCode Go: `~/.local/share/opencode/`
- Codex: `~/.codex/` and `~/.config/codex/`
- Cursor: `~/Library/Application Support/Cursor/User/globalStorage/`

The app is sandboxed and uses temporary read exceptions for those provider directories.

## Build

List schemes:

```sh
xcodebuild -list -project "ubos.xcodeproj"
```

Build the app:

```sh
xcodebuild build -project "ubos.xcodeproj" -scheme "ubos" -destination "platform=macOS"
```

Run unit tests:

```sh
xcodebuild test -project "ubos.xcodeproj" -scheme "ubos" -destination "platform=macOS" -only-testing:ubosTests
```

## Development Notes

- Main app target: `ubos`
- App entrypoint: `ubos/ubosApp.swift`
- Root popover UI: `ubos/ContentView.swift`
- Settings UI: `ubos/SettingsView.swift`
- Provider implementations live in `ubos/*UsageProvider.swift`

Xcode file-system synchronized groups are enabled, so files added under `ubos/`, `ubosTests/`, and `ubosUITests/` are picked up by folder membership.
