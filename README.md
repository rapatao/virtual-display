# Virtual Display

A macOS menu bar app that mirrors a resizable region of your screen into a standalone
window. Share that one window in a meeting, then drag any app into the region to put it
on the call, without ever re-picking the share target.

Google Meet, Slack and Microsoft Teams can share a whole display or a single window, never
an arbitrary rectangle. Virtual Display supplies the missing rectangle, as an ordinary
window that all of them can share. Zoom has **Share > Advanced > Portion of Screen** built
in, which covers a one-off share inside Zoom.

Beyond the rectangle: [presets](#region-presets) you can switch by name,
[global shortcuts](#keyboard-shortcuts), a [URL scheme](#commands-and-the-url-scheme) that
drives every command from a script or a Stream Deck, [screenshots and
recording](#screenshots-and-recording) of exactly what the meeting sees, and [Lua
plugins](#lua-plugins) that add commands, menu items and overlays.

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

To build it yourself instead, see [DEVELOPMENT.md](DEVELOPMENT.md).

## Requirements

- macOS 14 or later
- Screen Recording permission (the app requests it on first use)

---

## Usage

The app lives in the menu bar. A Dock icon appears only while mirroring is on, because
conferencing apps build their "share a window" list from applications that have a Dock
presence; turn mirroring off and it goes back to tray-only.

1. Click the menu bar icon and enable **Mirroring**. Grant Screen Recording if asked, then
   reopen the app.
2. Position the red **region frame** over the part of the screen you want to share. Drag
   from anywhere inside it, resize from any edge.
3. Turn **Edit Region** off. The frame turns green and becomes click-through, so windows
   underneath stay usable.
4. In your meeting pick Share > **Window** > **Virtual Display**. The output window opens
   automatically with mirroring; it is small on purpose and can sit behind everything
   else, but it must stay on screen and must not be minimised.
5. Drag any window into the region. It is now on the call.

### Menu reference

| Item | Behaviour |
| --- | --- |
| **Allow Screen Recording...** | Only visible when permission is missing. Raises the system prompt on first use, and deep-links to the correct Settings pane afterwards. |
| **Mirroring** | Starts and stops capture, and opens/closes the output window. `Ctrl Opt Cmd M`. Disabled while permission is missing. |
| **Pause** | Blanks the share without closing the output window, so the meeting keeps it selected. `Ctrl Opt Cmd P`. |
| **Edit Region** | On: the frame is red, draggable and resizable. Off: green and click-through. |
| **Follow Focused Window** | The region jumps to the front window of whatever app you switch to, see below. |
| **Region Presets** | Size and position presets, see below. |
| **Show Cursor in Share** | Whether your pointer appears in what you share. |
| **Launch at Login** | Registers the app with macOS via `SMAppService`. |
| **Copy Diagnostics** | Copies a report on screen state to the clipboard and displays it. Same output as `--doctor`. |
| **About Virtual Display...** | Version, license, and a **Check for Updates** button. |
| **Quit Virtual Display** | `Cmd Q` |

### Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `Ctrl Opt Cmd M` | Toggle mirroring |
| `Ctrl Opt Cmd P` | Toggle pause |
| `Ctrl Opt Cmd S` | Take a screenshot |
| `Ctrl Opt Cmd R` | Start or stop recording |

These are global: they work while another app is focused. They are registered through
Carbon's `RegisterEventHotKey`, which unlike an `NSEvent` global monitor needs no
Accessibility permission.

Binding one of these combinations in `config.json` overrides the default: config shortcuts
are registered first, and the built-in then does not claim the key. The action keeps its
menu item either way. See [Customising](#customising-without-a-new-release).

### Screenshots and recording

| Menu item | Produces |
| --- | --- |
| **Take Screenshot** | `~/Pictures/Virtual Display/Screenshot 2026-09-03 at 22.15.00.png` |
| **Start Recording** / **Stop Recording** | `~/Movies/Virtual Display/Recording 2026-09-03 at 22.15.00.mov` |

Both capture the output window, not the region, so what you get is exactly what the meeting
sees, overlays included. Stills are PNG at 1920x1080; recordings are H.264 in a QuickTime
container, 1920x1080 at 30fps, **video only, no audio**.

Both need the output window on screen, so both are greyed out unless mirroring is on. While
paused they still work, on the frozen picture. The menu bar icon becomes a record dot while
recording, since that is the state you must not forget about.

From a script or a plugin, with an optional destination:

```sh
open 'virtualdisplay://screenshot'
open 'virtualdisplay://start-recording?path=~/Desktop/demo.mov'
open 'virtualdisplay://stop-recording'
```

A recording is finalised when you stop it, when mirroring is turned off, when capture
fails, and when the app quits - an unfinalised `.mov` will not play, so quitting waits for
the file to close. If frames cannot be encoded fast enough they are dropped rather than
stalling the live mirror. A recording that never received a frame deletes its own stub and
says so.

### Menu bar icon states

| Icon | Meaning |
| --- | --- |
| Record dot | A recording is running |
| Two rectangles | Mirroring is live |
| Two rectangles, struck through | Mirroring is off |
| Pause symbol | Mirroring is on but paused |
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

**Snap to Window Below** sizes the region to the frontmost ordinary window under the
region's centre, which is the fiddly part of setup if done by hand.

Presets are clamped to the screen, so the frame can never be parked off-screen or made
larger than the display it sits on. Choosing a preset while the frame is hidden turns
**Edit Region** on so you can see where it landed.

### Follow Focused Window

**Follow Focused Window** does that snap automatically: the region moves and resizes onto
whichever window you are working in, so the meeting sees it without you touching the
frame. It keeps up with that window as you move or resize it, and follows a switch between
two windows of the *same* app as well as between apps. Turning it on snaps immediately.

While it is on, the region is not yours to place: the next check puts it back on the
focused window. Turn it off to position the frame by hand.

macOS has no per-window focus notification outside the Accessibility API, and this app
deliberately does not ask for that grant, so follow mode checks the frontmost window three
times a second using the window list it already reads for **Snap to Window Below**. The
timer only runs while following is actually on.

Some apps should never drag the region onto the call: the meeting app itself, a password
manager, a terminal with secrets in the scrollback. **Settings... > Follow** holds the
list; **Add App** picks from what is running, rows can be edited by hand for an app that is
not, and each row removes itself with the button beside it. Follow mode skips those apps, leaving the region on whatever it followed last.

The same list in `config.json`, for a machine you set up from a file:

```json
{ "followIgnores": ["Slack", "zoom.us", "com.1password.1password"] }
```

Each entry is matched, case-insensitively, against the app's name as it appears in the
menu bar or against its bundle id (`osascript -e 'id of app "Slack"'`). Whole names only,
no prefixes: `"Slack"` does not cover `"Slack Helper"`.

Pause suspends it, so a paused share cannot quietly change what it resumes to. The toggle
stays on and takes effect again when you resume. It is remembered across launches, and can
be turned on or off from a shortcut or a script like anything else
(`virtualdisplay://toggle-follow-focus`).

---

## Customising without a new release

Three levels, in order of how much you need. All of them live outside the app bundle, so
none of them survives only until the next upgrade, and none of them needs a rebuild.

| Want | Use | Where |
| --- | --- | --- |
| Sizes, shortcuts, capture folders, plugins | **Settings...** (`Cmd ,`) | menu bar |
| The same, by hand | `config.json` | `~/.config/virtual-display/config.json` |
| Drive the app from other software | `virtualdisplay://` URLs | anything that can run `open` |
| Behaviour the app does not have | Lua plugins | `~/.config/virtual-display/plugins/*.lua` |
| Text, images or live data on the stream | `vd.overlay` and `vd.fetch` in a plugin | same |

`XDG_CONFIG_HOME` is honoured if set. Working examples live in [`examples/`](examples).

### Settings

**Settings...** in the menu, or `Cmd ,`. Sections are listed down the left:

| Section | Does |
| --- | --- |
| Presets | Type a name and a size, or **Add Current Region Size** to capture the region as it is now. Rows are editable in place |
| Shortcuts | Click a shortcut, press the keys. Escape cancels, Delete clears. Recording one for an action replaces its default, and the menu updates to match |
| Follow | The Follow Focused Window switch, and the list of apps it leaves alone. **Add App** picks from what is running, so the name is spelled the way the matcher expects; each row has its own remove button |
| Captures | Where screenshots and recordings are written, or **Default** for the system folders |
| Plugins | The plugin switch, the folder, a reload button, and any load errors |
| About | Version, copyright, links to the repository and the bundled licence, and **Check for Updates** |

While the window is open the app takes a Dock icon, so it can be found again after it goes
behind something. Global shortcuts are handed back to the system while you are recording
one, otherwise Carbon would run the action instead of capturing the keys.

There is no Save button: every change is written to `config.json` immediately and applied
without a relaunch. The window and the file are the same settings, so hand-editing still
works - though a save rewrites the file whole, dropping any key this version does not know
about. After hand-editing, `open 'virtualdisplay://reload-config'` applies the file
without a relaunch, and refreshes the settings window if it is open.

`open 'virtualdisplay://settings?tab=shortcuts'` opens it on a particular section.

**Check for Updates** asks GitHub for the latest release and compares it with the running
version, only when you press it: there is no background check and nothing is sent. A newer
release offers a button to open its page; installing it is still `brew upgrade --cask
virtual-display` or a download.

### config.json

```json
{
  "presets": [{ "name": "Notes strip", "width": 700, "height": 1000 }],
  "hotkeys": {
    "ctrl-opt-cmd-r": "snap-to-window-below",
    "ctrl-opt-cmd-1": "set-size?width=1280&height=720"
  },
  "defaults": { "showsCursor": false },
  "captures": { "recordings": "~/Desktop" },
  "followIgnores": ["Slack", "com.1password.1password"]
}
```

Presets are added to the built-in ones, not replacing them. Hotkey values are commands
from the table below, with arguments in URL query form. Shortcut specs are modifiers plus
one key: `cmd`, `ctrl`, `opt` (or `alt`), `shift`, then a letter, digit, `f1`-`f20`, an
arrow, `space`, `return`, `tab`, `escape`, `delete`, `home`, `end`, `pageup`, `pagedown`,
or a punctuation key. `defaults` only applies to settings you have never toggled in the
menu; once you toggle one, your choice wins. `followIgnores` is the list of apps
[Follow Focused Window](#follow-focused-window) leaves alone.

Every key is optional; the ones you leave out keep their defaults.

A missing file is normal, and a malformed one is logged and ignored rather than stopping
the app from launching.

### Commands and the URL scheme

```sh
open 'virtualdisplay://toggle-mirroring'
open 'virtualdisplay://set-size?width=1280&height=720'
open 'virtualdisplay://set-region?x=100&y=100&w=960&h=540'
```

| Command | Arguments |
| --- | --- |
| `toggle-mirroring`, `set-mirroring` | `on=true\|false` |
| `toggle-pause`, `set-pause` | `on=` |
| `toggle-edit-region`, `set-edit-region` | `on=` |
| `toggle-follow-focus`, `set-follow-focus` | `on=` |
| `set-size` | `name=<preset prefix>`, or `width=` and `height=` |
| `set-spot` | `name=center\|top-left\|top-right\|bottom-left\|bottom-right` |
| `set-region` | `x= y= w= h=` in screen points |
| `region` | prints the region frame as JSON |
| `snap-to-window-below` | |
| `screenshot` | `path=` optional; returns where it will land |
| `start-recording`, `stop-recording`, `toggle-recording` | `path=` optional |
| `toggle-cursor`, `toggle-login-item`, `request-access` | |
| `copy-diagnostics`, `diagnostics` | |
| `state` | prints `AppState` as JSON |
| `commands` | lists every command, including any a plugin added |
| `reload-plugins` | re-reads the plugins directory |
| `reload-config` | re-reads `config.json`, so a hand-edit applies without a relaunch |
| `set-overlay` | `id=` plus `text=` or `image=`, and `x= y= w= h= size= color= background= align= alpha= z=` |
| `clear-overlay`, `clear-overlays` | `id=` / everything |

The menu, the global shortcuts, the URL scheme and the plugins all dispatch through this
one table, so a command can never do one thing from the menu and another from a script.

### Lua plugins

**Plugins are off until you turn them on**: tick **Enable Plugins** in the menu, or run
`open 'virtualdisplay://set-plugins?on=true'`. Then every `.lua` file in
`~/.config/virtual-display/plugins/` runs at launch, in filename order, against one shared
Lua 5.4 interpreter. **Reload Plugins** re-reads them without restarting the app; turning
the toggle off again unregisters everything they added.

Files that are not owned by you, or that are group- or world-writable, are skipped and
reported. A plugin runs with this app's Screen Recording grant, so a file that some other
process can rewrite must not be loaded.

| Call | Does |
| --- | --- |
| `vd.command(name, args)` | Runs any command. Returns its result, or `nil, message` |
| `vd.register(name, fn)` | Adds a command, reachable from `virtualdisplay://` too |
| `vd.on(event, fn)` | `mirroring`, `pause`, `edit_region`, `follow_focus`, `region_moved`, `capture_failed`, `menu_will_open` |
| `vd.hotkey(spec, fn)` | Global shortcut, same spec format as the config file |
| `vd.menu(title, fn)` | Adds a menu bar item |
| `vd.preset(name, width, height)` | Adds a region preset |
| `vd.region()` | `{ x, y, w, h }` of the region frame |
| `vd.windows()` | On-screen windows, front to back: `{ app, title, pid, x, y, w, h }` |
| `vd.state()` | The app state as a table of booleans |
| `vd.timer(seconds, fn)` | One-shot; call it again from `fn` to repeat |
| `vd.overlay(id, spec)` | Draws over the shared image. `spec = nil` removes it |
| `vd.on("screenshot", fn)` | Fires with `path`, `ok`; `"recording"` fires with `on`, `path` |
| `vd.clear_overlays()` | Removes all of them |
| `vd.fetch(url, opts, fn)` | HTTP; `fn(res)` gets `body`, `status`, `ok`, `error` |
| `vd.log(message)` | To the system log |

Nothing raises a Lua error at you: a call that fails returns `nil` and a message, the way
`io.open` does. An error thrown inside your own plugin is caught, logged, and shown behind
a **Plugin Error...** menu item; the other plugins still load.

```lua
vd.menu("Snap and share", function()
    vd.command("snap-to-window-below")
    vd.command("set-mirroring", { on = true })
end)
```

[`examples/plugins/follow-window.lua`](examples/plugins/follow-window.lua) uses the whole
API to keep the region glued to a chosen app's window.

#### Drawing on the stream

Overlays are drawn in the output window, which is the thing a meeting shares, so everyone
on the call sees them. The mirrored image underneath is untouched, and nothing is
composited into the capture pipeline.

```lua
vd.overlay("band",  { background = "#000000cc", x = 0, y = 0.86, w = 1, h = 0.14 })
vd.overlay("logo",  { image = "~/Pictures/logo.png", x = 0.02, y = 0.88, h = 0.1 })
vd.overlay("clock", { text = os.date("%H:%M"), x = 0.98, y = 0.89, size = 44, align = "right" })
vd.overlay("clock", nil)   -- remove
```

| Key | Meaning |
| --- | --- |
| `text` / `image` | A string, or a path to an image file. One overlay may carry both |
| `x`, `y` | Position as a fraction of the window: `0,0` top left, `1,1` bottom right |
| `w`, `h` | Size as a fraction of the window. Omit one on an image to keep its aspect |
| `size` | Font size in points on a 1920x1080 reference canvas, scaled to the window |
| `color`, `background` | `#rrggbb`, `#rrggbbaa`, `#rgb`, or `white`/`black`/`red`/... |
| `align` | `left`, `center`, `right`; `x` is that edge of the item |
| `alpha`, `z` | Opacity 0-1, and draw order. Equal `z` keeps insertion order |

Setting the same `id` again replaces it in place, so a clock ticking every second does not
climb over its neighbours. Everything is sized against a 1080-tall canvas, so overlays keep
their proportions when the output window is resized. Reloading plugins clears them.

The same thing without Lua:

```sh
open 'virtualdisplay://set-overlay?id=live&text=RECORDING&x=0.5&y=0.05&align=center&color=%23ff0000'
```

#### Talking to an API

`vd.fetch(url, options, callback)` does HTTP through `URLSession`. `options` is optional
and takes `method`, `body`, `timeout` and a nested `headers` table. The callback gets one
table: `body`, `status`, `ok`, `error`. It never raises, and bodies are capped at 4 MB and
decoded as text.

```lua
vd.fetch("https://api.example.com/now-playing",
         { headers = { Authorization = "Bearer " .. token } },
         function(res)
    if res.ok then
        vd.overlay("track", { text = res.body, x = 0.5, y = 0.92, align = "center" })
    end
end)
```

Combine with `vd.timer` to poll. [`examples/plugins/overlay-ticker.lua`](examples/plugins/overlay-ticker.lua)
is a lower third that does exactly that: logo, ticking clock, and a headline refreshed from
an API every 30 seconds, shown only while mirroring runs.

`vd.fetch` is the app's only outbound network call, and it happens only because a plugin
asked. It also means a plugin can send data out - though stock Lua's `io` and `os.execute`
already allow that, so it changes convenience, not exposure.

**Plugins are trusted code.** They run inside an app that holds Screen Recording
permission, so a plugin can capture your screen and, through `vd.fetch`, send what it
finds somewhere. There is no sandbox: treat the plugins directory the way you treat your
shell profile. That is why the feature is opt-in and why unsafe file permissions are
refused - anything able to write a file in your home directory would otherwise inherit
this app's permissions. Native module loading (`package.loadlib`, C `require`) is switched
off, since the hardened runtime blocks it anyway.

If a plugin wedges the app at launch:

```sh
defaults write com.rapatao.virtual-display enablePlugins -bool NO
```

---

## Behaviour notes

**The region is free-form.** Output is always a 1920x1080 canvas. When the region's aspect
ratio is not 16:9 the image is letterboxed inside it rather than stretched.

**The region frame and the output window are excluded from capture.** The output window
can sit on top of the region without producing an infinite mirror tunnel, and the red or
green frame never appears in what you share.

**The output window is not optional and is managed for you.** It opens when mirroring is
enabled and closes when mirroring is disabled, because it is the only thing a meeting can
actually share. Resize it freely; it stays 16:9 and may be left behind other windows.

**The output window has no title bar.** Picture edge to edge, so what the meeting sees
looks like a display rather than a window. It still *has* a title, "Virtual Display":
that is the name a share picker lists it under, and an untitled window is one some pickers
drop entirely. With no title bar to grab, drag the window by the picture itself. macOS
still rounds the top corners of any titled window; a meeting renders those few pixels
black.

**Turning mirroring off ends your share.** The window it was offering goes away, so the
meeting stops sharing rather than showing a frozen frame. Re-enable and pick the window
again to resume. To hide something mid-call, use **Pause** instead: capture stops and the
share goes black, but the window stays on screen and stays selected.

**Never minimise the output window.** A minimised window reports `onscreen=false` and is
dropped from every share picker, which looks exactly like the app being broken. It has no
minimise button for that reason.

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
| `followFocus` | Follow Focused Window toggle. Absent means off |
| `showsCursor` | Show Cursor in Share toggle |
| `didRequestScreenRecordingAccess` | Whether the system permission prompt has been shown |
| `enablePlugins` | Enable Plugins toggle. Absent means off |

Mirroring and pause are deliberately **not** persisted; the app always starts with capture
off and unpaused. Launch at Login lives in macOS, not here, so `defaults delete` will not
clear it - turn it off from the menu.

Inspect or reset:

```sh
defaults read com.rapatao.virtual-display
defaults delete com.rapatao.virtual-display
```

---

## Troubleshooting

**A shortcut does nothing.** **Copy Diagnostics** ends with a `shortcuts:` section listing
every shortcut as `active` or `TAKEN by another app`. Carbon hands a combination to
whoever registered it first, so another app holding it means ours never fires. Rebind it
in `config.json`.

**Asked for permission repeatedly.** Ad-hoc signing: the grant is pinned to the binary's
hash, so every build asks again. See [Signing](DEVELOPMENT.md#signing).

**Asked for permission again after a certificate renewal.** The grant was stored against a
requirement naming the old leaf certificate. Team-pinned builds do not have this problem;
see [Signing](DEVELOPMENT.md#signing).

**Finder shows a generic icon.** Icon Services cache. Run `touch VirtualDisplay.app` or
`killall Finder`.

**Nothing appears in the output window.** Confirm Screen Recording is on in System
Settings > Privacy & Security > Screen & System Audio Recording, then relaunch. macOS only
applies the change on the next launch.

**"Virtual Display" is missing from the meeting's share list.** Collect the facts first:
tray icon > **Copy Diagnostics**, which puts a report on the clipboard and shows it on
screen. The same report is available without the GUI:

```sh
/Applications/VirtualDisplay.app/Contents/MacOS/VirtualDisplay --doctor
```

`on-screen normal windows` is the set a picker draws from. If the output window is listed
there, the exclusion is on the conferencing app's side. If it only appears under `all
windows incl. off-screen`, it is positioned outside every display.

The app has **two** windows and they are easy to confuse:

| Window | Layer | Shareable |
| --- | --- | --- |
| Region frame (the red/green rectangle) | 3, floating | **Never.** Pickers only offer layer 0, and it is excluded from capture on purpose |
| Output window (titled Virtual Display) | 0 | **Yes.** This is the one to pick in the meeting |

Seeing the region frame on screen does not mean the output window is open. Check the
report: the output window is labelled, and it must appear under `on-screen normal windows`
with `onscreen=true`. If it is missing there, enable **Mirroring**, which opens it.

Common causes:

- It is a **window**, not a display. In Meet, Zoom or Slack, pick the **Window** tab. It
  will never appear under Entire Screen / Display.
- The output window must be **on screen** to be listed at all, and it only exists while
  **Mirroring** is on. Enable mirroring, then reopen the share picker.
- Never minimise it. macOS only enumerates on-screen windows, and a minimised one is not
  one.

---

## Contributing

- Building from source, code layout, signing a local build: [DEVELOPMENT.md](DEVELOPMENT.md)
- Tagging a version, CI secrets, the Homebrew tap: [RELEASING.md](RELEASING.md)

## License

Copyright (C) 2026 Luiz Henrique Rapatao.

GNU General Public License v3.0 or later. See [LICENSE](LICENSE).

Forks and derivative works must ship their source under the same license. Note that the
Mac App Store's terms are incompatible with the GPL, so a GPL-licensed build cannot be
distributed there.
