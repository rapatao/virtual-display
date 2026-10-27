# Configuration

## Customising without a new release

All of these live outside the app bundle, so upgrades leave them alone.

| Want | Use | Where |
| --- | --- | --- |
| Sizes, shortcuts, capture folders, plugins | [**Settings...**](#settings) (`Cmd ,`) | menu bar |
| The same, by hand | [`config.json`](#configjson) | `~/.config/virtual-display/config.json` |
| Drive the app from other software | [`virtualdisplay://` URLs](automation.md) | anything that can run `open` |
| Behaviour the app does not have | [Lua plugins](plugins.md) | `~/.config/virtual-display/plugins/*.lua` |
| Text, images or live data on the stream | [`vd.overlay`](plugins.md#overlays) and [`vd.fetch`](plugins.md#http) in a plugin | same |

`XDG_CONFIG_HOME` is honoured if set. Working examples live in [`examples/`](../examples).

## Settings

**Settings...** in the menu, or `Cmd ,`.

| Section | Does |
| --- | --- |
| Presets | Your presets. **Add Current Size** / **Add Current Region** capture the region, without or with its position |
| Output | The [output size](#output-size), [aspect lock](usage.md#aspect-lock), freeze on pause, and opening the output window off screen |
| Shortcuts | Click one, press the keys. Escape cancels, Delete clears |
| Follow | The [Follow Focused Window](usage.md#follow-focused-window) switch and the apps it skips. **Add App** picks from running apps |
| Privacy | The [apps hidden from the share](usage.md#hidden-apps) |
| Captures | Screenshot and recording folders, and microphone audio |
| Automation | The [token](automation.md#the-automation-token) and a rule per command |
| Plugins | The [plugin](plugins.md) switch, a per-file switch, and load errors |
| About | Version, licence, and **Check for Updates** |

`open 'virtualdisplay://settings?tab=shortcuts&token=YOUR-TOKEN'` opens a given section.

There is no Save button: every change is written to `config.json` and applied at once. A
save rewrites the file whole, dropping keys this version does not know. While the window is
open the app shows a Dock icon, and global shortcuts are paused while you record one.

**Check for Updates** asks GitHub for the latest release only when pressed; there is no
background check. Installing is still `brew upgrade --cask virtual-display` or a download.

## Output size

The canvas the mirror, screenshots and recordings are produced at. 1920x1080 by default;
**Settings... > Output** offers 1280x720, 2560x1440 and 3840x2160, and `config.json`
accepts any even size from 320 to 7680. Changes apply at once and the output window
reshapes to match.

A region larger than the canvas is downsampled, which costs a shared terminal its
legibility. A larger canvas keeps the detail at the cost of encoding work at both ends.

## config.json

```json
{
  "presets": [
    { "name": "Notes strip", "width": 700, "height": 1000 },
    { "name": "Demo spot", "width": 1280, "height": 720, "x": 240, "y": 300 }
  ],
  "hotkeys": {
    "ctrl-opt-cmd-r": "snap-to-window-below",
    "ctrl-opt-cmd-1": "set-size?width=1280&height=720"
  },
  "defaults": { "showsCursor": false, "lockAspect": true },
  "output": { "width": 2560, "height": 1440 },
  "freezeOnPause": true,
  "captures": { "recordings": "~/Desktop", "microphone": true },
  "followIgnores": ["Slack", "com.1password.1password"],
  "excludedApps": ["com.apple.notificationcenterui", "Slack"],
  "disabledPlugins": ["20-ticker.lua"]
}
```

Every key is optional. A missing file is normal; a malformed one is logged and ignored.

| Key | Meaning |
| --- | --- |
| `presets` | Added to the built-in ones. `x` and `y` together give a position; either alone is ignored |
| `hotkeys` | Shortcut spec to a [command](automation.md#commands-and-the-url-scheme), arguments in URL query form |
| `defaults` | Initial menu toggles (`showsCursor`, `lockAspect`, `highlightClicks`). Ignored once you toggle one in the menu |
| `output` | The [output size](#output-size), clamped to even numbers from 320 to 7680 |
| `freezeOnPause` | Hold the last frame while paused instead of blanking |
| `captures` | `screenshots` and `recordings` folders, and `microphone` for recordings |
| `followIgnores` | Apps [Follow Focused Window](usage.md#follow-focused-window) skips |
| `excludedApps` | [Apps hidden from the share](usage.md#hidden-apps) |
| `disabledPlugins` | [Plugin files](plugins.md) left unloaded, by file name |

A shortcut spec is modifiers (`cmd`, `ctrl`, `opt` or `alt`, `shift`) plus one key: a
letter, digit, `f1`-`f20`, an arrow, `space`, `return`, `tab`, `escape`, `delete`, `home`,
`end`, `pageup`, `pagedown`, or a punctuation key.

After hand-editing, apply the file without a relaunch:

```sh
open 'virtualdisplay://reload-config?token=YOUR-TOKEN'
```

## Saved state

Stored in `UserDefaults` under `com.rapatao.virtual-display`:

| Key | Contents |
| --- | --- |
| `NSWindow Frame RegionWindow` | Region frame position and size |
| `NSWindow Frame OutputWindow` | Output window position and size |
| `editRegion` | Edit Region toggle |
| `followFocus` | Follow Focused Window toggle. Absent means off |
| `showsCursor` | Show Cursor in Share toggle |
| `highlightClicks` | Highlight Clicks in Share toggle. Absent means off |
| `lockAspect` | Lock Region Aspect toggle. Absent means off |
| `didRequestScreenRecordingAccess` | Whether the system permission prompt has been shown |
| `enablePlugins` | Enable Plugins toggle. Absent means off |
| `requireAutomationToken` | The [token requirement](automation.md#the-automation-token). Absent means on |
| `automationToken` | The token itself, made the first time it is needed |
| `drawTool`, `drawColor`, `drawWidth` | The last [drawing](usage.md#drawing) tool, colour (`#rrggbbaa`) and line width in points |
| `automationGrants` | The per-command rule by name (`deny`, `alwaysAsk`, `askOnce`, `allow`, `acceptWithoutToken`); absent means Default |

Mirroring, pause and drawing are not saved: the app always starts with them off. Launch at
Login lives in macOS, so `defaults delete` does not clear it; use the menu. Deleting the
domain regenerates the token, breaking scripts that carry the old one.

Inspect or reset:

```sh
defaults read com.rapatao.virtual-display
defaults delete com.rapatao.virtual-display
```
