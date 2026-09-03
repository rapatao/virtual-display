# Virtual Display

A macOS menu bar app that mirrors a resizable region of your screen into a standalone
window. Share that one window in a meeting, then drag any app into the region to put it
on the call, without ever re-picking the share target.

Google Meet, Zoom and Slack can share a whole display or a single window, never an
arbitrary rectangle. Virtual Display supplies the missing rectangle.

---

## Install

### Homebrew

```sh
brew install --cask rapatao/tap/virtual-display
```

The cask clears the quarantine flag on install, so the app launches without a Gatekeeper
detour. Upgrade with `brew upgrade --cask virtual-display`, remove with
`brew uninstall --cask virtual-display`, and `brew uninstall --zap --cask virtual-display`
to also delete saved preferences.

### Manual

Download `VirtualDisplay.zip` from the [Releases](../../releases) page, unzip, and move
`VirtualDisplay.app` to `/Applications`.

Unless the release was notarized, macOS quarantines anything downloaded from the web and
refuses to open it. Clear the flag once:

```sh
xattr -d com.apple.quarantine /Applications/VirtualDisplay.app
```

Releases are universal binaries covering both Apple Silicon and Intel.

## Requirements

- macOS 14 or later
- Xcode command line tools (`xcode-select --install`)
- Screen Recording permission (the app requests it on first use)

## Build and install

```sh
./bundle.sh
open VirtualDisplay.app
```

`bundle.sh` compiles a release build, generates the app icon if needed, assembles
`VirtualDisplay.app`, and code signs it. Move the `.app` anywhere you like, or add it to
System Settings > General > Login Items to have it start with the machine.

### Signing

By default the bundle is ad-hoc signed. macOS ties the Screen Recording grant to the
binary's hash in that case, so **every rebuild is treated as a new app and re-asks for
permission**. To keep the grant across rebuilds, sign with a stable identity:

1. Keychain Access > Certificate Assistant > **Create a Certificate...**
2. Name it `Virtual Display Dev`, set Certificate Type to **Code Signing**, self-signed
3. Build with that identity:

```sh
VD_SIGN_ID="Virtual Display Dev" ./bundle.sh
```

When `VD_SIGN_ID` is set, the bundle is signed with the hardened runtime and a secure
timestamp, which notarization requires. Ad-hoc signing supports neither.

---

## Releases via GitHub Actions

`.github/workflows/release.yml` builds, runs `--selftest`, signs, optionally notarizes,
and attaches `VirtualDisplay.zip` to a GitHub Release. It runs on any `v*` tag and can be
triggered manually from the Actions tab, which uploads a build artifact instead of
publishing a release.

```sh
git tag v1.0 && git push origin v1.0
```

Every secret below is optional. With none of them set, the workflow still produces a
working ad-hoc signed build.

### Signing in CI

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

### Notarization in CI

Only possible with a Developer ID Application certificate. Leave these unset otherwise and
the step is skipped.

| Secret | Contents |
| --- | --- |
| `NOTARY_APPLE_ID` | Apple ID email |
| `NOTARY_TEAM_ID` | 10-character Team ID |
| `NOTARY_PASSWORD` | An [app-specific password](https://appleid.apple.com), not your account password |

### Homebrew tap

| Secret | Contents |
| --- | --- |
| `GH_RELEASE_TOKEN` | A token with write access to `rapatao/homebrew-tap` |

On a tag build the workflow checksums `VirtualDisplay.zip`, regenerates
`Casks/virtual-display.rb` in the tap, and pushes it. Unset the secret and the step is
skipped; the GitHub Release is still published.

### What each signing level buys

| | Ad-hoc | Apple Development | Developer ID |
| --- | --- | --- | --- |
| Stable code identity, Screen Recording grant survives updates | no | yes | yes |
| Can be notarized | no | no | yes |
| Opens on another Mac without clearing quarantine | no | no | yes |

macOS ties the Screen Recording grant to the binary hash for ad-hoc builds, so every
ad-hoc release re-asks for permission. Any real certificate fixes that.

---

## Usage

The app lives entirely in the menu bar. There is no Dock icon and no app menu.

1. Click the menu bar icon and enable **Mirroring**. Grant Screen Recording if asked, then
   reopen the app.
2. Position the red **region frame** over the part of the screen you want to share. Drag
   from anywhere inside it, resize from any edge.
3. Turn **Edit Region** off. The frame turns green and becomes click-through, so windows
   underneath stay usable.
4. Choose **Show Output Window**, then in your meeting pick Share > Window > **Virtual
   Display**.
5. Drag any window into the region. It is now on the call.

### Menu reference

| Item | Behaviour |
| --- | --- |
| **Allow Screen Recording...** | Only visible when permission is missing. Raises the system prompt on first use, and deep-links to the correct Settings pane afterwards. |
| **Mirroring** | Starts and stops capture. Disabled while permission is missing. |
| **Edit Region** | On: the frame is red, draggable and resizable. Off: green and click-through. |
| **Region Presets** | Size and position presets, see below. |
| **Show Output Window** | Shows or hides the window you share in the meeting. |
| **Quit Virtual Display** | `Cmd Q` |

### Menu bar icon states

| Icon | Meaning |
| --- | --- |
| Two rectangles | Mirroring is live |
| Two rectangles, struck through | Mirroring is off |
| Warning triangle | Screen Recording permission is missing |

### Region presets

Sizes are in points and grow downward from the frame's current top edge.

| Size | Notes |
| --- | --- |
| 960 x 540 | 1:1 on a Retina display: exactly the 1920x1080 output canvas, no resampling |
| 1280 x 720 | |
| 1920 x 1080 | |
| Half Screen | Half the screen width, 16:9, computed at click time |

Positions: **Center**, **Top Left**, **Top Right**, **Bottom Left**, **Bottom Right**,
relative to the visible area of the screen the frame is on (excluding menu bar and Dock).

Presets are clamped to the screen, so the frame can never be parked off-screen or made
larger than the display it sits on. Choosing a preset while the frame is hidden turns
**Edit Region** on so you can see where it landed.

---

## Behaviour notes

**The region is free-form.** Output is always a 1920x1080 canvas. When the region's aspect
ratio is not 16:9 the image is letterboxed inside it rather than stretched.

**The region frame and the output window are excluded from capture.** The output window
can sit on top of the region without producing an infinite mirror tunnel, and the red or
green frame never appears in what you share.

**Disabling mirroring does not end your share.** The output window stays open and goes
black, so the meeting keeps the window selected and you can resume by re-enabling.
*Hiding* the output window does end the share, because macOS only shares on-screen
windows. Toggle it between calls, not during one.

**The region frame is independent of mirroring.** It is visible whenever you are editing
it or mirroring is live, so the region can be positioned before a call starts.

**Recurring permission prompt.** macOS periodically shows "requesting to bypass the system
private window picker and directly access your screen and audio". This app builds its own
capture filter rather than using `SCContentSharingPicker`, which is what triggers the
reminder. The grant is still valid; the prompt is informational.

---

## Saved state

Stored in `UserDefaults` under `com.rapatao.virtual-display`:

| Key | Contents |
| --- | --- |
| `NSWindow Frame RegionWindow` | Region frame position and size |
| `NSWindow Frame OutputWindow` | Output window position and size |
| `editRegion` | Edit Region toggle |
| `didRequestScreenRecordingAccess` | Whether the system permission prompt has been shown |

Mirroring is deliberately **not** persisted; the app always starts with capture off.

Inspect or reset:

```sh
defaults read com.rapatao.virtual-display
defaults delete com.rapatao.virtual-display
```

---

## Development

```sh
swift build                          # debug build
.build/debug/VirtualDisplay --selftest   # geometry checks, prints "selftest OK"
./bundle.sh                          # release build + app bundle
```

`--selftest` covers the two pieces of pure geometry: the AppKit-to-CoreGraphics
coordinate flip used to derive the capture rectangle, and the screen clamp applied to
preset frames. It runs before any AppKit setup, so it works headless and in CI.

### Layout

| Path | Contents |
| --- | --- |
| `Sources/VirtualDisplay/main.swift` | The entire app: geometry, region overlay, status item, capture stream |
| `Package.swift` | SwiftPM manifest, no dependencies |
| `bundle.sh` | Release build, icon generation, `.app` assembly, code signing |
| `makeicon.swift` | Draws `VirtualDisplay.iconset` from vectors; run via `swift makeicon.swift` |

### How capture works

ScreenCaptureKit does the cropping. `SCStreamConfiguration.sourceRect` is set to the
region frame converted into display coordinates, and `SCContentFilter(display:
excludingWindows:)` removes the app's own two windows from the capture. Moving or
resizing the region calls `SCStream.updateConfiguration`; dragging it to another display
rebuilds the filter via `SCStream.updateContentFilter`. Frames arrive as
`CMSampleBuffer`s and are enqueued into an `AVSampleBufferDisplayLayer`.

### Changing the icon

Edit the rectangles and gradient colours in `makeicon.swift`, then run `./bundle.sh`. The
icon is regenerated only when `makeicon.swift` is newer than `VirtualDisplay.icns`.

---

## Troubleshooting

**Asked for permission repeatedly.** Ad-hoc signing, see [Signing](#signing).

**Finder shows a generic icon.** Icon Services cache. Run `touch VirtualDisplay.app` or
`killall Finder`.

**Nothing appears in the output window.** Confirm Screen Recording is on in System
Settings > Privacy & Security > Screen & System Audio Recording, then relaunch. macOS only
applies the change on the next launch.

**"Virtual Display" is missing from the meeting's share list.** Two causes:

- It is a **window**, not a display. In Meet, Zoom or Slack, pick the **Window** tab. It
  will never appear under Entire Screen / Display.
- The output window must be **on screen** to be listed at all, and it starts hidden on a
  fresh install. Choose **Show Output Window** from the tray menu, then reopen the share
  picker. Do not minimise it; macOS only enumerates on-screen windows.

The choice is remembered, so this only comes up the first time on a given machine.
