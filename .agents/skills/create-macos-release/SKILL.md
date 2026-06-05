---
name: create-macos-release
description: Create a tag-based macOS GitHub release for a native Xcode app with Developer ID signing, notarization, DMG packaging, Sparkle EdDSA signing, appcast.xml updates, git tag/push, and gh release creation. Use when the user asks to create, publish, ship, cut, or update a macOS release, especially for Sparkle-enabled apps distributed through GitHub Releases.
---

# Create macOS Release

Use this skill for real macOS distribution releases, not just local debug builds. The expected output is a pushed release commit, a pushed tag, a notarized DMG attached to a GitHub release, and an appcast entry whose Sparkle signature matches the final stapled DMG bytes.

## Guardrails

- Do not overwrite an existing tag or GitHub release unless the user explicitly asks.
- Do not silently replace an already-published release asset. Prefer a new patch version and build number.
- Do not publish from a dirty worktree without explaining unrelated changes and keeping the release commit scoped.
- Always compute the Sparkle signature after Developer ID signing, notarization, and stapling. Earlier signatures are invalid after the DMG bytes change.
- For private GitHub repositories, warn that Sparkle cannot fetch the raw appcast publicly unless the feed is hosted somewhere accessible to installed apps.

## Fast Preflight

Run the bundled checker first:

```sh
.agents/skills/create-macos-release/scripts/preflight.sh
```

Confirm:

- `gh`, `git`, `create-dmg`, `xcodebuild`, `xcrun`, and `xmllint` exist.
- A `Developer ID Application` identity exists.
- `notarytool` credentials work, usually through `--keychain-profile notarytool`.
- Sparkle tools exist, especially `sign_update`.
- `release.json` and `appcast.xml` exist.
- The worktree state is understood.

## Version And Tag

Choose the next tag before building.

- If the previous released tag is `v1.0`, use `v1.0.1` for a patch release.
- Ensure `CURRENT_PROJECT_VERSION` increases monotonically for Sparkle.
- Update every app/test target `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the Xcode project unless the repo intentionally version-splits targets.
- Use a tag that matches the marketing version: `1.0.1` -> `v1.0.1`.

Check current values:

```sh
rg -n "CURRENT_PROJECT_VERSION =|MARKETING_VERSION =" *.xcodeproj/project.pbxproj
gh release list --limit 10
git tag --list --sort=-creatordate
```

## Build, Archive, Export

Build Release first:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build \
  -project "APP.xcodeproj" \
  -scheme "APP" \
  -configuration Release \
  -destination "platform=macOS"
```

Archive with Developer ID signing:

```sh
rm -rf build/APP.xcarchive build/export
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild archive \
  -project "APP.xcodeproj" \
  -scheme "APP" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "build/APP.xcarchive" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM=TEAMID \
  PROVISIONING_PROFILE_SPECIFIER=""
```

Export with a Developer ID export options plist:

```xml
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>teamID</key>
  <string>TEAMID</string>
</dict>
```

```sh
xcodebuild -exportArchive \
  -archivePath "build/APP.xcarchive" \
  -exportPath "build/export" \
  -exportOptionsPlist "build/exportOptions.plist"
```

Verify:

```sh
plutil -p "build/export/APP.app/Contents/Info.plist" | grep -E "CFBundleShortVersionString|CFBundleVersion|SUFeedURL|SUPublicEDKey"
codesign --verify --deep --strict --verbose=2 "build/export/APP.app"
spctl -a -vvv -t exec "build/export/APP.app"
```

## Create, Sign, Notarize DMG

Create the DMG:

```sh
create-dmg \
  --volname "APP" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 160 \
  --icon "APP.app" 180 170 \
  --app-drop-link 480 170 \
  --hide-extension "APP.app" \
  "build/APP-VERSION.dmg" \
  "build/export/APP.app"
```

Sign the DMG container:

```sh
codesign --force --sign "Developer ID Application: NAME (TEAMID)" --timestamp --options runtime "build/APP-VERSION.dmg"
```

Notarize and staple:

```sh
xcrun notarytool submit "build/APP-VERSION.dmg" --keychain-profile notarytool --wait
xcrun stapler staple "build/APP-VERSION.dmg"
xcrun stapler validate "build/APP-VERSION.dmg"
spctl -a -vvv -t install "build/APP-VERSION.dmg"
```

## Sparkle Appcast

Find `sign_update`:

```sh
find ~/Library/Developer/Xcode/DerivedData -path "*/Sparkle/bin/sign_update" -type f | head -1
```

Compute signature after stapling:

```sh
/path/to/sign_update "build/APP-VERSION.dmg"
```

Add the new `<item>` at the top of `appcast.xml`:

```xml
<item>
  <title>Version VERSION (Build BUILD)</title>
  <pubDate>DATE_RFC_2822</pubDate>
  <sparkle:version>BUILD</sparkle:version>
  <sparkle:shortVersionString>VERSION</sparkle:shortVersionString>
  <sparkle:minimumSystemVersion>MIN_MACOS</sparkle:minimumSystemVersion>
  <description><![CDATA[<ul><li>Release note.</li></ul>]]></description>
  <enclosure url="https://github.com/OWNER/REPO/releases/download/vVERSION/APP-VERSION.dmg"
             type="application/octet-stream"
             sparkle:edSignature="SIGNATURE"
             length="LENGTH" />
</item>
```

Validate:

```sh
xmllint --noout appcast.xml
```

## Commit, Tag, Publish

Commit the version bump and appcast together:

```sh
git add appcast.xml APP.xcodeproj/project.pbxproj
git commit -m "Release vVERSION"
git tag -a vVERSION -m "vVERSION"
git push origin main
git push origin vVERSION
```

Create the GitHub release from the existing pushed tag:

```sh
gh release create vVERSION "build/APP-VERSION.dmg" \
  --repo OWNER/REPO \
  --title "vVERSION" \
  --notes "- Release note"
```

Verify:

```sh
git rev-parse vVERSION^{}
git rev-parse HEAD
gh release view vVERSION --repo OWNER/REPO --json tagName,url,assets,isDraft,isPrerelease
```

The tag commit should match `HEAD` for a just-cut release unless the user intentionally releases an older commit.
