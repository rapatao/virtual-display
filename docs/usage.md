# Usage

The app lives in the menu bar. It shows a Dock icon only while mirroring is on, because
conferencing apps list shareable windows only from apps with a Dock presence.

First-time setup is the [quick start](../README.md#quick-start) in the README.

## Menu reference

| Item | Behaviour |
| --- | --- |
| **Allow Screen Recording...** | Only visible when permission is missing. Raises the system prompt on first use, then deep-links to the Settings pane. |
| **Mirroring** | Starts and stops capture, and opens/closes the output window. Disabled while permission is missing. |
| **Pause** | Blanks the share without closing the output window, so the meeting keeps it selected. |
| **Edit Region** | On: the frame is red, draggable and resizable. Off: green and click-through. |
| **Draw** | Draw over the region, see [Drawing](#drawing). |
| **Follow Focused Window** | The region follows the front window, see [below](#follow-focused-window). |
| **Lock Region Aspect** | Holds the region to the shape of the output, see [Aspect lock](#aspect-lock). |
| **Region Presets** | Size and position presets, see [below](#region-presets). |
| **Region spans two displays** | A warning, only visible when the region lies across two screens, which capture cannot do. |
| **Show Cursor in Share** | Whether your pointer appears in the share. |
| **Highlight Clicks in Share** | A yellow ring grows and fades wherever you click inside the region. Only the share shows it. Off by default, or `"highlightClicks": true` under `defaults` in [config.json](configuration.md#configjson). |
| **Launch at Login** | Registers the app with macOS via `SMAppService`. |
| **Take Screenshot** / **Copy Screenshot** | A PNG of the share, to a file or the clipboard. See [below](#screenshots-and-recording). |
| **Start Recording** / **Stop Recording** | Records the share to a `.mov`. |
| **Settings...** | The [settings window](configuration.md#settings). `Cmd ,` |
| **Copy Diagnostics** | Copies a report on screen state to the clipboard and displays it. Same output as `--doctor`. |
| **Enable Plugins** / **Reload Plugins** | The [plugin](plugins.md) switch, off by default, and a re-read of the folder. |
| **About Virtual Display...** | Version, license, and **Check for Updates**. |
| **Quit Virtual Display** | `Cmd Q` |

The menu bar icon shows the state:

| Icon | Meaning |
| --- | --- |
| Record dot | A recording is running |
| Two rectangles | Mirroring is live |
| Two rectangles, struck through | Mirroring is off |
| Pause symbol | Mirroring is on but paused |
| Warning triangle | Screen Recording permission is missing |

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `Ctrl Opt Cmd M` | Toggle mirroring |
| `Ctrl Opt Cmd P` | Toggle pause |
| `Ctrl Opt Cmd S` | Take a screenshot |
| `Ctrl Opt Cmd R` | Start or stop recording |
| `Ctrl Opt Cmd D` | Toggle drawing |

They are global and need no Accessibility permission (Carbon's `RegisterEventHotKey`).
Each one shows a short HUD line on screen, since the menu bar icon is the only other
feedback while another app is focused. The HUD is never captured.

Rebind them in **Settings... > Shortcuts** or under `hotkeys` in
[config.json](configuration.md#configjson). A binding there takes the key from the
built-in; the action keeps its menu item.

## Drawing

**Draw** turns the frame orange and makes it take the mouse, so you can draw on the
region. The meeting sees the strokes, and so do screenshots and recordings. Windows under
the region cannot be clicked while you draw. Drawing works with mirroring off, and turns
**Edit Region** off.

A toolbar sits above the region:

| Control | Does |
| --- | --- |
| Pen / Highlighter / Laser | Pen draws solid lines, highlighter wide see-through ones. Laser, the default, fades about 1.5 seconds after you let go. |
| Swatches and colour well | The ink colour. The well opens the system colour picker. |
| Width | 1 to 20 points. The dot beside it previews the next stroke. |
| Undo | Removes the last non-laser stroke. Also `Cmd Z`. |
| Clear | Removes every stroke |
| Close | Stops drawing. Also `Esc` |

Leaving draw mode removes every stroke. Tool, colour and width are remembered. Strokes are
stored relative to the region, so they move and scale with it.

## Screenshots and recording

| Menu item | Produces |
| --- | --- |
| **Take Screenshot** | `~/Pictures/Virtual Display/Screenshot 2026-09-03 at 22.15.00.png` |
| **Copy Screenshot** | The same picture on the clipboard, no file |
| **Start Recording** / **Stop Recording** | `~/Movies/Virtual Display/Recording 2026-09-03 at 22.15.00.mov` |

Both capture the output window, so you get exactly what the meeting sees, overlays
included. Stills are PNG and recordings H.264 at 30fps, both at the
[output size](configuration.md#output-size). Folders are set in **Settings... > Captures**.

Recordings are silent unless **Settings... > Captures > Record microphone audio** is on.
System audio cannot be recorded: ScreenCaptureKit ties audio to the captured window, and
this app's window is silent. If the microphone fails to open, the picture is still
recorded and the HUD says so.

Both are greyed out unless mirroring is on, and while paused, since the share is blank
then. With **Freeze the last frame when paused** on, they stay available.

A recording is finalised when you stop it, turn mirroring off, capture fails, or the app
quits; quitting waits for the file to close. Frames that cannot be encoded in time are
dropped rather than stalling the mirror. A recording that never got a frame deletes
itself.

Scripts and plugins can pass a destination:

```sh
open 'virtualdisplay://screenshot?clipboard=true&token=YOUR-TOKEN'
open 'virtualdisplay://start-recording?path=~/Desktop/demo.mov&mic=true&token=YOUR-TOKEN'
open 'virtualdisplay://stop-recording?token=YOUR-TOKEN'
```

See [Automation](automation.md) for the token.

## Region presets

Sizes are in points and grow downward from the frame's top edge.

| Size | Notes |
| --- | --- |
| 960 x 540 | On a Retina display, exactly the 1920x1080 canvas, no resampling |
| 1280 x 720 | |
| 1920 x 1080 | |
| Half Screen | Half the screen width, 16:9 |

Positions: **Center**, **Top Left**, **Top Right**, **Bottom Left**, **Bottom Right**,
within the visible area of the frame's screen (excluding menu bar and Dock).

**Snap to Window Below** fits the region to the frontmost window under its centre.

Presets are clamped to the screen. Choosing one while the frame is hidden turns **Edit
Region** on so you can see where it landed.

Your own presets, added in **Settings... > Presets**, can carry a position as well as a
size. **Add Current Region** captures both; a preset without a position resizes the
region in place.

## Aspect lock

A region whose shape differs from the output is letterboxed: black bars on two sides.
**Lock Region Aspect** holds the region to the output's shape (16:9 unless you changed the
[output size](configuration.md#output-size)) while dragging, and applies it to presets,
snapping and follow mode. Off by default, remembered across launches.

## Follow Focused Window

The region moves and resizes onto whichever window you are working in, including when you
move or resize it, or switch between windows of the same app. While on, the region cannot
be placed by hand.

The app does not use the Accessibility API, so it polls the frontmost window three times a
second, only while following is on. Pause suspends following, so a paused share cannot
change what it resumes to. Remembered across launches.

**Settings... > Follow** lists apps to skip, such as the meeting app or a password manager;
the region stays on whatever it followed last. A skipped app still shows in the share if
its window is inside the region. To keep it off the call, [hide it](#hidden-apps) too. In
`config.json`:

```json
{ "followIgnores": ["Slack", "zoom.us", "com.1password.1password"] }
```

Entries match the app's menu bar name or its bundle id (`osascript -e 'id of app
"Slack"'`), case-insensitively, whole names only: `"Slack"` does not cover
`"Slack Helper"`.

## Hidden apps

Windows of hidden apps are left out of the capture, so the meeting sees what is beneath
them. Notification Center is hidden by default, keeping banners off the call. Follow mode
skips hidden apps too.

**Settings... > Privacy** holds the list. In `config.json`:

```json
{ "excludedApps": ["com.apple.notificationcenterui", "Slack", "com.1password.1password"] }
```

Entries match like `followIgnores`. Leaving the key out keeps the default;
`"excludedApps": []` hides nothing, banners included. An app launched while mirroring is
hidden as soon as it starts.

## Behaviour notes

**The app's own windows are never captured.** The output window can overlap the region
without an infinite mirror, and the frame, alerts, settings and HUD never reach the share.

**The output window exists only while mirroring.** It is the thing the meeting shares, so
turning mirroring off ends the share; re-enable and pick the window again. To hide
something mid-call, use **Pause**: the window stays selected and the share goes black, or
holds the last frame with **Freeze the last frame when paused** on.

**Size the output window 1:1.** It opens at one canvas pixel per screen pixel (960 x 540
points for 1920x1080 on Retina). Meetings share the window's pixels, so a smaller window is
shared upscaled and soft. It may sit behind other windows.

**Never minimise it.** A minimised window is dropped from every share picker. It has no
minimise button for that reason.

**No title bar.** The picture goes edge to edge; drag the window by the picture. The window
keeps the title "Virtual Display", which is what share pickers list. macOS rounds its top
corners, which the meeting shows as a few black pixels.

**The frame is independent of mirroring.** It shows while editing or mirroring, so you can
place the region before a call.

**Recurring permission prompt.** macOS periodically says the app is "requesting to bypass
the system private window picker and directly access your screen and audio". It appears
because the app builds its own capture filter instead of using `SCContentSharingPicker`.
The grant is still valid.
