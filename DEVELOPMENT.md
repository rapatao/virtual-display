# Development

Building Virtual Display from source, how the code is arranged, and how to sign a local
build so macOS stops re-asking for Screen Recording. For cutting a release, see
[RELEASING.md](RELEASING.md).

## Requirements

- macOS 14 or later
- Xcode command line tools (`xcode-select --install`)

## Build

```sh
swift build      # debug build
swift test       # unit tests, headless, no GUI session needed
./bundle.sh      # release build + app bundle
open VirtualDisplay.app
```

`bundle.sh` compiles a release build, generates the app icon if needed, assembles
`VirtualDisplay.app`, and code signs it. Move the `.app` anywhere you like, or add it to
System Settings > General > Login Items to have it start with the machine.

---

## Signing

By default the bundle is ad-hoc signed, and its designated requirement is then a bare
cdhash:

```
designated => cdhash H"7a56e51e..."
```

macOS records that requirement when you grant Screen Recording and matches later builds
against it, so **every rebuild is a new app and asks for permission again** - and so is
every release, for everyone who installed the last one.

Signing with any stable identity fixes it:

```sh
VD_SIGN_ID="Apple Development: you@example.com (XXXXXXXXXX)" ./bundle.sh
```

`security find-identity -v -p codesigning` lists what you have. Put the export in your
shell profile and plain `./bundle.sh` picks it up.

For an Apple-issued certificate the script goes one step further and pins the requirement
to the **team**, not to the certificate:

```
designated => identifier "com.rapatao.virtual-display" and anchor apple generic
              and certificate leaf[subject.OU] = "TEAMID"
```

codesign's own default names the leaf certificate, which means the grant dies the day that
certificate is renewed, or when an Apple Development certificate is traded for a Developer
ID one. Pinning the team outlives both. A self-signed certificate has no team and no Apple
anchor, so those keep the default requirement and still survive rebuilds.

The requirement stored by macOS is the one that was in force **when the permission was
granted**. After switching to a team-pinned build, grant once more to store the durable
one:

```sh
tccutil reset ScreenCapture com.rapatao.virtual-display
defaults delete com.rapatao.virtual-display didRequestScreenRecordingAccess
```

The second line matters: `tccutil` clears the system grant but not the app's own record of
having asked, and without it the app assumes macOS will not prompt again and shows its own
alert instead.

When `VD_SIGN_ID` is set, the bundle is also signed with the hardened runtime and a secure
timestamp, which notarization requires. Ad-hoc signing supports neither.

If the identity does not appear in `find-identity`, the usual cause is a missing
intermediate rather than a bad certificate: an Apple Development certificate is issued by
**WWDR G3**, and a machine carrying only the expired G1 fails with `errSecInternalComponent`
and "unable to build chain to self-signed root". Install the current intermediate from
[Apple's certificate authority page](https://www.apple.com/certificateauthority/).

---

## Layout

The app is a thin executable over a `VirtualDisplayCore` library, so the logic can be
unit tested; an executable target cannot be imported by a test target.

| Path | Contents |
| --- | --- |
| `Sources/VirtualDisplay/main.swift` | Three lines: calls `Launch.main()` |
| `Sources/VirtualDisplayCore/Launch.swift` | Command line flags, then `NSApplication` bootstrap |
| `Sources/VirtualDisplayCore/AppState.swift` | Every UI rule, as derived properties. Start here |
| `Sources/VirtualDisplayCore/AppCoordinator.swift` | Owns the state, wires the pieces, handles actions |
| `Sources/VirtualDisplayCore/CaptureController.swift` | The ScreenCaptureKit stream and nothing else |
| `Sources/VirtualDisplayCore/RegionWindow.swift` | The floating frame: placement, presets, snapping |
| `Sources/VirtualDisplayCore/OutputWindow.swift` | The shareable window and its frame sink |
| `Sources/VirtualDisplayCore/StatusMenu.swift` | Menu bar item; renders `AppState`, decides nothing |
| `Sources/VirtualDisplayCore/Geometry.swift` | Pure coordinate maths, no AppKit |
| `Sources/VirtualDisplayCore/Preferences.swift` | Persisted settings and the login item |
| `Sources/VirtualDisplayCore/ScreenRecordingPermission.swift` | Reading, requesting, and explaining the grant |
| `Sources/VirtualDisplayCore/HotKeyCenter.swift` | Carbon global hot keys |
| `Sources/VirtualDisplayCore/CommandCenter.swift` | Every action by name; menu, hot keys, URLs and plugins dispatch here |
| `Sources/VirtualDisplayCore/Config.swift` | `~/.config/virtual-display/config.json` and where the plugins live |
| `Sources/VirtualDisplayCore/KeySpec.swift` | `"ctrl-opt-cmd-r"` into a Carbon key code |
| `Sources/VirtualDisplayCore/LuaRuntime.swift` | The plugin interpreter and the `vd` API |
| `Sources/VirtualDisplayCore/Overlay.swift` | Text, images and rectangles drawn over the shared window |
| `Sources/VirtualDisplayCore/Fetch.swift` | The one outbound HTTP path, for `vd.fetch` |
| `Sources/VirtualDisplayCore/Recording.swift` | Screenshots and `.mov` recording of the shared window |
| `Sources/VirtualDisplayCore/SettingsWindow.swift` | The settings window; writes `config.json` |
| `Sources/CLua/` | Lua 5.4.8, vendored verbatim. See its `README.md` |
| `Sources/VirtualDisplayCore/Diagnostics.swift` | The `--doctor` report |
| `bundle.sh` | Release build, icon generation, `.app` assembly, code signing |
| `makeicon.swift` | Draws `VirtualDisplay.iconset` from vectors |

## How it fits together

`AppState` holds the truth; `AppCoordinator.render()` is the only thing that turns it
into visible effects: window order, activation policy, menu, and whether capture runs.
Actions mutate state and call `render()`. Nothing else decides what is visible, which is
what keeps the enable, pause, permission-revoke and failure paths from disagreeing.

## How capture works

ScreenCaptureKit does the cropping. `SCStreamConfiguration.sourceRect` is set to the
region frame converted into display coordinates, and `SCContentFilter(display:
excludingWindows:)` removes the app's own two windows from the capture. Moving or
resizing the region calls `SCStream.updateConfiguration`; dragging it to another display
rebuilds the filter via `SCStream.updateContentFilter`. Frames arrive as
`CMSampleBuffer`s and go to a `VideoSink`, which hops them to the main queue and into an
`AVSampleBufferDisplayLayer`.

`CaptureController` never reaches into a window: a `Source` struct supplies the rectangle
and the window numbers to exclude. Choosing them differently (an `SCContentSharingPicker`,
a second region) touches only the caller.

## Adding things

- **An action**: one `commands.register(...)` call in `AppCoordinator.registerCommands()`.
  It is then reachable from the menu, a shortcut, a URL and a plugin at once.
- **A menu item**: one `ActionMenuItem("Title") { ... }` in `StatusMenu`, calling a command.
  No selector, no `@objc` method elsewhere.
- **A visibility rule**: a derived property on `AppState`, used by `render()`, covered by
  `AppStateTests`.
- **A global shortcut**: one `HotKeyCenter.shared.register(keyCode:) { ... }` call.
- **A setting**: a case in `Preferences.Key` and a typed property beside it.
- **A plugin event**: one `lua.emit("name", [...])` call where the thing happens.

Anything a user might want to vary belongs in `config.json` or the `vd` API instead, so it
does not need a release. See
[Customising](README.md#customising-without-a-new-release).

## Changing the icon

Edit the rectangles and gradient colours in `makeicon.swift`, then run `./bundle.sh`. The
icon is regenerated only when `makeicon.swift` is newer than `VirtualDisplay.icns`.
