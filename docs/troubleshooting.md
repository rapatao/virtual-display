# Troubleshooting

Most answers start with **Copy Diagnostics** in the menu, which puts a report on the
clipboard and shows it. Without the GUI:

```sh
/Applications/VirtualDisplay.app/Contents/MacOS/VirtualDisplay --doctor
```

`--doctor` runs in a separate process, so it lacks the `region` and `shortcuts` sections.

## "Virtual Display" is missing from the meeting's share list

- Pick the **Window** tab, not Entire Screen / Display.
- Mirroring must be on: the output window exists only then. Seeing the red/green region
  frame does not mean the output window is open.
- The output window must be at least partly on screen and not minimised.

In the report, the output window must appear under `on-screen normal windows` with
`onscreen=true`. If it does, the conferencing app is excluding it. If it appears only under
`all windows incl. off-screen`, it is outside every display.

| Window | Layer | Shareable |
| --- | --- | --- |
| Region frame (red/green rectangle) | 3, floating | **Never.** Pickers offer layer 0 only, and it is excluded from capture |
| Output window (titled Virtual Display) | 0 | **Yes.** Pick this one |

## Nothing appears in the output window

Check System Settings > Privacy & Security > Screen & System Audio Recording, then
relaunch: macOS applies the grant only on the next launch.

## Half the shared picture is the wrong thing

The region spans two displays, and capture reads only one; the other part shows whatever
is at that rectangle on the first screen. The menu warns under Region Presets, and the
report repeats it. Move or shrink the region onto one screen.

## A shortcut does nothing

The report's `shortcuts:` section marks each one `active` or `TAKEN by another app`. The
first app to register a combination gets it. Rebind in **Settings... > Shortcuts** or
`config.json`.

## A `virtualdisplay://` URL does nothing, or a `Blocked:` HUD appears

The URL needs `token=` from **Settings... > Automation** (or an answer to the dialog, if the
token requirement is off), and the command must not be set to **Deny**. See
[Automation](automation.md#the-automation-token).

## Asked for permission repeatedly

Ad-hoc signed builds pin the grant to the binary's hash, so every build asks again. A grant
can also be lost after a certificate renewal if it names the old leaf certificate;
team-pinned builds avoid both. See [Signing](../DEVELOPMENT.md#signing).

## Finder shows a generic icon

Icon Services cache. Run `touch VirtualDisplay.app` or `killall Finder`.
