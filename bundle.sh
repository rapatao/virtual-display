#!/bin/bash
# Builds VirtualDisplay.app. A bundle + stable (ad-hoc) signature is required so the
# Screen Recording TCC grant sticks to this app instead of re-prompting every launch.
set -euo pipefail
cd "$(dirname "$0")"

APP="VirtualDisplay.app"
VERSION="${VD_VERSION:-0.0.0}"

# Universal, so one release artifact covers Apple Silicon and Intel and the Homebrew
# cask needs a single url and checksum instead of per-arch blocks.
BUILD=(swift build -c release --arch arm64 --arch x86_64)
"${BUILD[@]}"
BIN="$("${BUILD[@]}" --show-bin-path)/VirtualDisplay"

# Regenerate only when the source drawing is newer than the icon.
if [ ! -f VirtualDisplay.icns ] || [ makeicon.swift -nt VirtualDisplay.icns ]; then
    swift makeicon.swift
    iconutil -c icns VirtualDisplay.iconset -o VirtualDisplay.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VirtualDisplay"
cp VirtualDisplay.icns "$APP/Contents/Resources/VirtualDisplay.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>VirtualDisplay</string>
    <key>CFBundleIconFile</key><string>VirtualDisplay</string>
    <key>CFBundleIdentifier</key><string>com.rapatao.virtual-display</string>
    <key>CFBundleName</key><string>Virtual Display</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signing pins the TCC grant to the binary's cdhash, so every rebuild reads as a
# new app and macOS asks for Screen Recording again. Sign with a stable self-signed
# identity to keep the grant across rebuilds:
#   Keychain Access > Certificate Assistant > Create a Certificate...
#     name: Virtual Display Dev, type: Code Signing, self-signed
#   VD_SIGN_ID="Virtual Display Dev" ./bundle.sh
if [ -z "${VD_SIGN_ID:-}" ]; then
    codesign --force --sign - "$APP"
    echo "built $APP (ad-hoc signed)"
else
    # Hardened runtime and a secure timestamp are required for notarization, and
    # neither is available to an ad-hoc signature.
    codesign --force --options runtime --timestamp --sign "$VD_SIGN_ID" "$APP"
    echo "built $APP (signed: $VD_SIGN_ID)"
fi
