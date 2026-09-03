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
    <!-- The automation channel: open 'virtualdisplay://toggle-mirroring' from anything. -->
    <key>CFBundleURLTypes</key>
    <array><dict>
        <key>CFBundleURLName</key><string>com.rapatao.virtual-display</string>
        <key>CFBundleURLSchemes</key><array><string>virtualdisplay</string></array>
    </dict></array>
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
    # macOS stores an app's designated requirement when a permission is granted and
    # matches later builds against it. The default requirement for an Apple-issued
    # certificate names the leaf certificate, so the Screen Recording grant survives a
    # rebuild but dies the day the certificate is renewed, or when Development is traded
    # for Developer ID. Pinning the team instead outlives both: same team, same grant, so
    # neither you nor anyone who installed a release has to allow it twice.
    # VD_TEAM_ID short-circuits the lookup, for a keychain the search list does not cover.
    # The `|| true` is load-bearing: under `set -o pipefail` a certificate that is not in
    # the keychain would otherwise abort the script here, right after a successful build
    # and without printing anything.
    TEAM="${VD_TEAM_ID:-$(security find-certificate -c "$VD_SIGN_ID" -p 2>/dev/null \
            | openssl x509 -noout -subject 2>/dev/null \
            | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p' || true)}"

    REQUIREMENT=()
    if [ -n "$TEAM" ]; then
        # "anchor apple generic" needs an Apple-issued chain, which a self-signed
        # certificate does not have; those keep the default requirement. The
        # "designated =>" prefix is not optional: without it codesign rejects the text.
        REQUIREMENT=(-r="designated => identifier \"com.rapatao.virtual-display\" and anchor apple generic and certificate leaf[subject.OU] = \"$TEAM\"")
    else
        echo "note: no team found for \"$VD_SIGN_ID\"; using codesign's default requirement." >&2
        echo "      Self-signed is expected here. For an Apple certificate, set VD_TEAM_ID." >&2
    fi

    # Hardened runtime and a secure timestamp are required for notarization, and
    # neither is available to an ad-hoc signature.
    codesign --force --options runtime --timestamp "${REQUIREMENT[@]}" \
             --sign "$VD_SIGN_ID" "$APP"
    echo "built $APP (signed: $VD_SIGN_ID${TEAM:+, team $TEAM})"
fi
