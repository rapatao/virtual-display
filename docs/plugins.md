# Lua plugins

Plugins are off by default. Turn them on with **Enable Plugins** in the menu. Every `.lua`
file in `~/.config/virtual-display/plugins/` then runs at launch, in filename order, in one
shared Lua 5.4 interpreter. **Reload Plugins** re-reads them; turning plugins off removes
everything they added.

**Plugins are trusted code.** They run with this app's Screen Recording permission and can
send what they capture out through `vd.fetch`, `io` or `os.execute`. There is no sandbox:
treat the plugins folder like your shell profile. For the same reason, files not owned by
you, or group- or world-writable, are skipped and reported. Native modules
(`package.loadlib`, C `require`) are disabled.

If a plugin hangs the app at launch:

```sh
defaults write com.rapatao.virtual-display enablePlugins -bool NO
```

**Settings... > Plugins** lists the files in load order, each with its own switch and any
load error. A disabled file stays on disk, and everything it registered goes away. New
files appear after **Reload**. The switches are stored as `disabledPlugins` in
[config.json](configuration.md#configjson).

## API

| Call | Does |
| --- | --- |
| `vd.command(name, args)` | Runs any [command](automation.md#commands-and-the-url-scheme). Returns its result, or `nil, message` |
| `vd.register(name, fn)` | Adds a command, reachable from `virtualdisplay://` and listed in Settings > Automation |
| `vd.on(event, fn)` | `mirroring`, `pause`, `edit_region`, `draw`, `follow_focus`, `region_moved`, `capture_failed`, `menu_will_open`, `screenshot` (`path`, `ok`), `recording` (`on`, `path`) |
| `vd.hotkey(spec, fn)` | Global shortcut, [spec format](configuration.md#configjson) as in `config.json` |
| `vd.menu(title, fn)` | Adds a menu bar item |
| `vd.preset(name, width, height)` | Adds a region preset |
| `vd.region()` | `{ x, y, w, h }` of the region frame |
| `vd.windows()` | On-screen windows, front to back: `{ app, title, pid, x, y, w, h }` |
| `vd.state()` | The app state as a table of booleans |
| `vd.timer(seconds, fn)` | One-shot; call it again from `fn` to repeat |
| `vd.overlay(id, spec)` | Draws over the share, see [below](#overlays). `spec = nil` removes it |
| `vd.clear_overlays()` | Removes all overlays |
| `vd.fetch(url, opts, fn)` | HTTP, see [below](#http) |
| `vd.log(message)` | To the system log |

Calls never raise: a failure returns `nil` and a message, like `io.open`. An error thrown
by a plugin is caught, logged and shown under a **Plugin Error...** menu item; other plugins
still load.

```lua
vd.menu("Snap and share", function()
    vd.command("snap-to-window-below")
    vd.command("set-mirroring", { on = true })
end)
```

[`examples/plugins/follow-window.lua`](../examples/plugins/follow-window.lua) uses most of
the API to keep the region on a chosen app's window.

## Overlays

Overlays are drawn in the output window, so the meeting sees them; the mirrored image is
untouched.

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

Setting an existing `id` replaces it in place. Overlays keep their proportions when the
window is resized, and reloading plugins clears them.

Without Lua:

```sh
open 'virtualdisplay://set-overlay?id=live&text=RECORDING&x=0.5&y=0.05&align=center&color=%23ff0000&token=YOUR-TOKEN'
```

## HTTP

`vd.fetch(url, options, callback)` uses `URLSession`. `options` is optional: `method`,
`body`, `timeout` and a `headers` table. The callback gets `body`, `status`, `ok` and
`error`. Bodies are capped at 4 MB and decoded as text.

```lua
vd.fetch("https://api.example.com/now-playing",
         { headers = { Authorization = "Bearer " .. token } },
         function(res)
    if res.ok then
        vd.overlay("track", { text = res.body, x = 0.5, y = 0.92, align = "center" })
    end
end)
```

Poll with `vd.timer`. [`examples/plugins/overlay-ticker.lua`](../examples/plugins/overlay-ticker.lua)
is a lower third with a logo, a clock and a headline refreshed every 30 seconds, shown only
while mirroring.
