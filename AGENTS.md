# AGENTS.md

## Project Shape
- Native macOS SwiftUI app in `ubos.xcodeproj`; the only scheme is `ubos`.
- Main app target: `ubos`; test targets: `ubosTests` and `ubosUITests`.
- App entrypoint is `ubos/ubosApp.swift`; root UI is `ubos/ContentView.swift`; SwiftData model currently lives in `ubos/Item.swift`.
- `ubos.xcodeproj` uses Xcode file-system synchronized groups, so files under `ubos/`, `ubosTests/`, and `ubosUITests/` are target members by folder rather than explicit `PBXBuildFile` entries.
- `.agents/skills/` and `skills-lock.json` are repo-local OpenCode skill assets, not app source.

## Build And Test
- List schemes/targets: `xcodebuild -list -project "ubos.xcodeproj"`.
- Build the app: `xcodebuild build -project "ubos.xcodeproj" -scheme "ubos" -destination "platform=macOS"`.
- Run unit tests only: `xcodebuild test -project "ubos.xcodeproj" -scheme "ubos" -destination "platform=macOS" -only-testing:ubosTests`.
- The `ubos` scheme still builds `ubosUITests` when filtering to `ubosTests`; the filter limits execution, not all compilation work.
- No repo lint, formatter, CI workflow, package manifest, or external dependency lockfile is present.

## Xcode Settings To Preserve
- Minimum macOS deployment target is `26.2`; SDK builds were verified with Xcode's macOS 26.2 SDK.
- App bundle identifier is `com.enru.ubos`; Xcode generates the Info.plist (`GENERATE_INFOPLIST_FILE = YES`).
- Automatic code signing uses development team `2Z79866758`; the app has sandbox and hardened runtime enabled, with user-selected file access set to read-only.
- Swift build settings enable approachable concurrency and default actor isolation to `MainActor`; avoid adding unnecessary manual `@MainActor` annotations to already main-isolated app code.
