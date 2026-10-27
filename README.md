# Virtual Display

A macOS menu bar app that mirrors a resizable region of your screen into a standalone
window. Share that one window in a meeting, then drag any app into the region to put it
on the call, without ever re-picking the share target.

Google Meet, Slack and Microsoft Teams can share a whole display or a single window, never
an arbitrary rectangle. Virtual Display supplies the missing rectangle, as an ordinary
window that all of them can share. Zoom has **Share > Advanced > Portion of Screen** built
in, which covers a one-off share inside Zoom.

## Features

- [Region presets](docs/usage.md#region-presets), an [aspect lock](docs/usage.md#aspect-lock)
  and a region that can [follow the focused window](docs/usage.md#follow-focused-window)
- [Drawing](docs/usage.md#drawing) over the region, and
  [click highlights](docs/usage.md#menu-reference) the meeting can see
- [Hidden apps](docs/usage.md#hidden-apps): notification banners and chosen apps never
  reach the share
- [Screenshots and recording](docs/usage.md#screenshots-and-recording) of exactly what the
  meeting sees
- [Global shortcuts](docs/usage.md#keyboard-shortcuts) that need no Accessibility permission
- A [token-gated URL scheme](docs/automation.md) that drives every command from a script or
  a Stream Deck
- [Lua plugins](docs/plugins.md) that add commands, menu items and overlays

## Install

Requires macOS 14 or later. Releases are universal binaries covering both Apple Silicon
and Intel.

### Homebrew

```sh
brew install --cask rapatao/tap/virtual-display
```

The cask clears the quarantine flag on install, so the app launches without a Gatekeeper
detour. Upgrade with `brew upgrade --cask virtual-display`, remove with
`brew uninstall --cask virtual-display`, and `brew uninstall --zap --cask virtual-display`
to also delete saved preferences.

### Nix

The package lives in the [rapatao NUR repository](https://github.com/rapatao/nur-packages)
as `nur.repos.rapatao.virtual-display`, or straight from that repository:

```sh
nix profile install github:rapatao/nur-packages#virtual-display
```

It installs `VirtualDisplay.app` under the profile's `Applications` directory. Nix does
not quarantine what it fetches, so the app launches without the Gatekeeper detour.

### Manual

Download `VirtualDisplay.zip` from the [Releases](../../releases) page, unzip, and move
`VirtualDisplay.app` to `/Applications`. Unless the release was notarized, macOS
quarantines it and refuses to open it. Clear the flag once:

```sh
xattr -d com.apple.quarantine /Applications/VirtualDisplay.app
```

To build it yourself instead, see [DEVELOPMENT.md](DEVELOPMENT.md).

## Quick start

1. Click the menu bar icon and enable **Mirroring**. Grant Screen Recording if asked, then
   reopen the app.
2. Position the red **region frame** over the part of the screen you want to share. Drag
   from anywhere inside it, resize from any edge.
3. Turn **Edit Region** off. The frame turns green and becomes click-through, so windows
   underneath stay usable.
4. In your meeting pick Share > **Window** > **Virtual Display**. The output window opens
   automatically with mirroring. It can sit behind everything else or be dragged mostly
   off the edge of the display, and the meeting still gets the full picture; keep some of
   it on screen and never minimise it. **Settings > Output > Open the output window off
   screen** does that for you, leaving only a corner showing at the bottom right.
5. Drag any window into the region. It is now on the call.

## Documentation

| Page | Covers |
| --- | --- |
| [Usage](docs/usage.md) | The menu, shortcuts, drawing, captures, presets, follow mode, hidden apps, behaviour notes |
| [Configuration](docs/configuration.md) | The settings window, output size, `config.json`, saved state |
| [Automation](docs/automation.md) | The `virtualdisplay://` commands and the automation token |
| [Plugins](docs/plugins.md) | The Lua `vd` API, overlays, HTTP |
| [Troubleshooting](docs/troubleshooting.md) | Shortcuts, permissions, the app missing from a share picker |

Working examples live in [`examples/`](examples).

## Contributing

- Building from source, code layout, signing a local build: [DEVELOPMENT.md](DEVELOPMENT.md)
- Tagging a version, CI secrets, the Homebrew tap: [RELEASING.md](RELEASING.md)

## License

Copyright (C) 2026 Luiz Henrique Rapatao.

GNU General Public License v3.0 or later. See [LICENSE](LICENSE).

Forks and derivative works must ship their source under the same license. Note that the
Mac App Store's terms are incompatible with the GPL, so a GPL-licensed build cannot be
distributed there.
