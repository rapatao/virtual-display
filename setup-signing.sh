#!/bin/bash
# Writes signing.env, which bundle.sh reads, so rebuilds keep the Screen Recording grant.
# Optional: without signing.env, bundle.sh signs ad-hoc as before.
set -euo pipefail
cd "$(dirname "$0")"

IDENTITIES=()
while IFS= read -r name; do
    IDENTITIES+=("$name")
done < <(security find-identity -v -p codesigning | sed -n 's/^ *[0-9]*) [0-9A-F]* "\(.*\)"$/\1/p')

case ${#IDENTITIES[@]} in
    0)
        echo "No code signing identity in the keychain. Create one, then run this again:" >&2
        echo "  Keychain Access > Certificate Assistant > Create a Certificate..." >&2
        echo "    name: Virtual Display Dev, type: Code Signing, self-signed" >&2
        exit 1
        ;;
    1)
        ID="${IDENTITIES[0]}"
        ;;
    *)
        echo "Pick the identity to sign local builds with:"
        select ID in "${IDENTITIES[@]}"; do
            [ -n "$ID" ] && break
        done
        ;;
esac

printf 'VD_SIGN_ID=%q\n' "$ID" > signing.env
echo "wrote signing.env: $ID"
echo
echo "Run ./bundle.sh, then clear the grant tied to the old ad-hoc builds and allow once more:"
echo "  tccutil reset ScreenCapture com.rapatao.virtual-display"
echo "  defaults delete com.rapatao.virtual-display didRequestScreenRecordingAccess"
