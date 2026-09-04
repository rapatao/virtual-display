# Releasing

`.github/workflows/release.yml` builds, runs `swift test`, signs, optionally notarizes,
and attaches `VirtualDisplay.zip` to a GitHub Release. It runs on any `v*` tag and can be
triggered manually from the Actions tab, which uploads a build artifact instead of
publishing a release.

```sh
git tag v1.0 && git push origin v1.0
```

Every secret below is optional. With none of them set, the workflow still produces a
working ad-hoc signed build. For what signing does locally, see
[DEVELOPMENT.md](DEVELOPMENT.md#signing).

## Signing in CI

| Secret | Contents |
| --- | --- |
| `MACOS_CERT_P12` | Base64 of your exported `.p12` |
| `MACOS_CERT_PASSWORD` | The password you set when exporting it |

Create an **Apple Development** certificate with a free Apple ID:

1. **Xcode > Settings > Accounts**, add your Apple ID, select the team
2. **Manage Certificates...** > **+** > **Apple Development**
3. **Keychain Access > login > My Certificates**, right-click *Apple Development: name
   (TEAMID)* > **Export...**, save as `.p12` with a password
4. Encode it and add both secrets to the repository:

```sh
base64 -i Certificates.p12 | pbcopy
```

A **Developer ID Application** certificate (paid Apple Developer Program) is created the
same way and is the only kind that can be notarized.

## Notarization

Only possible with a Developer ID Application certificate. Leave these unset otherwise and
the step is skipped.

| Secret | Contents |
| --- | --- |
| `NOTARY_APPLE_ID` | Apple ID email |
| `NOTARY_TEAM_ID` | 10-character Team ID |
| `NOTARY_PASSWORD` | An [app-specific password](https://appleid.apple.com), not your account password |

## Homebrew tap

| Secret | Contents |
| --- | --- |
| `GH_RELEASE_TOKEN` | A token with write access to `rapatao/homebrew-tap` |

On a tag build the workflow checksums `VirtualDisplay.zip`, regenerates
`Casks/virtual-display.rb` in the tap, and pushes it. Unset the secret and the step is
skipped; the GitHub Release is still published.

## What each signing level buys

| | Ad-hoc | Apple Development | Developer ID |
| --- | --- | --- | --- |
| Stable code identity, Screen Recording grant survives updates | no | yes | yes |
| Can be notarized | no | no | yes |
| Opens on another Mac without clearing quarantine | no | no | yes |

macOS ties the Screen Recording grant to the binary hash for ad-hoc builds, so every
ad-hoc release re-asks for permission. Any real certificate fixes that.

## License in the bundle

`bundle.sh` copies `LICENSE` into `VirtualDisplay.app/Contents/Resources/`. The release
zip and the Homebrew cask both carry the `.app` and nothing else, so that copy is what
satisfies GPL section 4 for anyone who installs a binary. Do not drop it from the bundle.
