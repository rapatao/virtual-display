# Automation

## Commands and the URL scheme

The menu, global shortcuts, `virtualdisplay://` URLs and plugins all run the same commands,
so a command behaves the same from every entry point.

```sh
open 'virtualdisplay://toggle-mirroring?token=YOUR-TOKEN'
open 'virtualdisplay://set-size?width=1280&height=720&token=YOUR-TOKEN'
open 'virtualdisplay://set-region?x=100&y=100&w=960&h=540&token=YOUR-TOKEN'
```

Commands sent as URLs need the [automation token](#the-automation-token). From the menu, a
shortcut or a plugin they do not.

| Command | Arguments |
| --- | --- |
| `toggle-mirroring`, `set-mirroring` | `on=true\|false` |
| `toggle-pause`, `set-pause` | `on=` |
| `toggle-edit-region`, `set-edit-region` | `on=` |
| `toggle-draw`, `set-draw` | `on=` |
| `undo-drawing`, `clear-drawing` | |
| `toggle-follow-focus`, `set-follow-focus` | `on=` |
| `toggle-aspect-lock`, `set-aspect-lock` | `on=` |
| `toggle-plugins`, `set-plugins` | `on=` |
| `set-size` | `name=<preset prefix>`, or `width=` and `height=` |
| `set-spot` | `name=center\|top-left\|top-right\|bottom-left\|bottom-right` |
| `set-region` | `x= y= w= h=` in screen points |
| `region` | prints the region frame as JSON |
| `snap-to-window-below` | |
| `screenshot` | `path=` optional, or `clipboard=true`; returns where it will land |
| `start-recording`, `stop-recording`, `toggle-recording` | `path=` optional, `mic=true\|false` overrides the setting |
| `toggle-cursor`, `toggle-click-highlight`, `toggle-login-item`, `request-access` | |
| `copy-diagnostics`, `diagnostics` | |
| `settings` | `tab=` optional, opens the settings window on that section |
| `state` | prints `AppState` as JSON |
| `commands` | lists every command, including any a plugin added |
| `reload-plugins` | re-reads the plugins directory |
| `reload-config` | re-reads `config.json` |
| `set-overlay` | `id=` plus `text=` or `image=`, and `x= y= w= h= size= color= background= align= alpha= z=` |
| `clear-overlay`, `clear-overlays` | `id=` / everything |

## The automation token

Any web page can open a URL, and the browser's "Open Virtual Display?" prompt does not say
that yes may start a screen recording. So every command sent as a URL is guarded, even
harmless-looking ones: a page that can move the region can park it over something private.

By default a URL needs the token from **Settings... > Automation**. **Copy URL** there puts a
working example on the clipboard. **Regenerate** replaces a leaked token, breaking every
script that uses the old one. The token is stripped before the command runs.

Turn **Require a token** off and each command instead asks the first time a URL calls it.
The answer, **Don't Allow** included, is remembered.

Each command also has a rule, set in the same pane:

| Rule | Require a token **on** | Require a token **off** |
| --- | --- | --- |
| **Default** | needs the token | asks once, keeps the answer |
| **Deny** | refused, however good the token | refused |
| **Always ask** | needs the token, then asks every time | asks every time |
| **Ask once** | needs the token, then asks until answered | asks until answered |
| **Allow** | needs the token, then runs | runs |
| **Accept without token** | runs, no token | runs |

The token says who is calling; the rule says what that caller may run. Both must pass, so a
**Deny** command is refused even with a valid token. Tokens leak into shell history,
dotfiles and screenshots, so set commands you never script to **Deny** and a stolen token is
worth little. **Allow** only skips the question; **Accept without token** is the one way to
drop the token for a command.

**Always ask** offers only **Don't Allow** and **Allow Once**, since it never remembers.
**Reset All** puts every command back to Default. A refused command shows a
`Blocked: <command>` HUD.

None of this applies to the menu, global shortcuts, `hotkeys` in `config.json`, or plugins,
so a locked-out script never locks you out of the app.
