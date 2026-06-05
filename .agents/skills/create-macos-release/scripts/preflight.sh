#!/usr/bin/env bash
set -euo pipefail

echo "== tools =="
for tool in git gh xcodebuild xcrun create-dmg xmllint; do
  if command -v "$tool" >/dev/null 2>&1; then
    printf "ok  %s -> %s\n" "$tool" "$(command -v "$tool")"
  else
    printf "ERR %s missing\n" "$tool"
  fi
done

echo
echo "== repo =="
git status --short --branch || true
git tag --list --sort=-creatordate | head -10 || true

echo
echo "== release config =="
test -f release.json && sed -n '1,120p' release.json || echo "release.json missing"
test -f appcast.xml && xmllint --noout appcast.xml && echo "appcast.xml valid" || echo "appcast.xml missing or invalid"

echo
echo "== xcode =="
project="$(find . -maxdepth 2 -name '*.xcodeproj' | head -1)"
if [[ -n "${project}" ]]; then
  echo "project: ${project}"
  xcodebuild -list -project "${project}" 2>/dev/null | sed -n '/Schemes:/,$p' | head -20
  rg -n "CURRENT_PROJECT_VERSION =|MARKETING_VERSION =|PRODUCT_BUNDLE_IDENTIFIER =|DEVELOPMENT_TEAM =" "${project}/project.pbxproj" || true
else
  echo "no .xcodeproj found"
fi

echo
echo "== signing =="
security find-identity -v -p codesigning | grep -E "Developer ID Application|Apple Development" || true
xcrun notarytool history --keychain-profile notarytool >/dev/null 2>&1 \
  && echo "ok  notarytool profile: notarytool" \
  || echo "WARN no working notarytool profile named notarytool"

echo
echo "== sparkle =="
find ~/Library/Developer/Xcode/DerivedData -path "*/Sparkle/bin/sign_update" -type f 2>/dev/null | head -5
