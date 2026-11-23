# Troubleshooting

Most answers start with **Copy Diagnostics** in the menu, which puts a report on the
clipboard and shows it. Without the GUI:

```sh
/Applications/VirtualDisplay.app/Contents/MacOS/VirtualDisplay --doctor
```

`--doctor` runs in a separate process, so it lacks the `region` and `shortcuts` sections.

## "Virtual Display" is missing from the meeting's share list

- In window mode, pick the **Window** tab, not Entire Screen / Display.
- With [Share as a display](usage.md#share-as-a-display) on, pick the virtual display under
  **Screen** instead.
- In Chrome's system picker, the **Share** button may appear in the middle of the chosen
  screen. If you cannot see it, check that screen, which can mean moving the pointer onto
  the virtual display.
- Mirroring must be on: the output window, or the virtual display in that mode, exists
  only then. Seeing the red/green region frame does not mean either is up.
- In window mode, the output window must be at least partly on screen and not minimised.

In window mode, the output window must appear under `on-screen normal windows` with
`onscreen=true`. If it does, the conferencing app is excluding it. If it appears only under
`all windows incl. off-screen`, it is outside every display. With Share as a display on, the
output window should appear in the report's window list, and the `screens:` list should
include a line ending in `VIRTUAL SCREEN`.

| Window | Layer | Shareable |
| --- | --- | --- |
| Region frame (red/green rectangle) | 3, floating | **Never.** Pickers offer layer 0 only, and it is excluded from capture |
| Output window (titled Virtual Display) | 0 | **Yes.** Pick this one |
| Output window in display mode (fills the virtual display) | screen saver level | Pick the virtual display under **Screen** instead |

## An extra display appears, or the pointer lands on it

With [Share as a display](usage.md#share-as-a-display) on, the virtual display is a real
display while mirroring runs. It has a place in **System Settings > Displays**, and the
pointer crosses onto it at that edge of the arrangement. Move it in that pane to change
where that is. A region on it is moved onto a real display when the output window is shown
there, whenever the screen layout changes, and after a move onto it ends. Stopping
mirroring removes it. A change to the setting takes effect the next time mirroring starts,
so a display still showing while mirroring runs is expected.

The display has fixed vendor, product and serial numbers, so macOS remembers its place in
the arrangement and any choice to make it the main display or to mirror it. If it was made
the main display or is mirrored, starting mirroring falls back to the window and shows one of
the messages above. Its arrangement and mirroring can be changed in **System Settings >
Displays**.

## Fallback to a window

When the virtual display cannot be used, the output window is used instead. The first three
messages mean that. The HUD shows each one at that moment, and the same line goes to the
log. The last reports a failed resize rather than a fallback:

| HUD message | Cause | What to do |
| --- | --- | --- |
| Share as a display is unavailable, using a window | macOS outside 14 through 27, or the private display API is missing or refused to create the display | Pick the **Window** tab. `--doctor` shows `virtual display supported here: false` on an unsupported macOS |
| The virtual display did not appear, using a window | It was not published within about 2 seconds of being created, or it was already offline, mirrored, or the main display when the window was to be shown | Pick the **Window** tab. Starting mirroring again tries the display once more |
| The virtual display went away, using a window | It went offline, was mirrored onto another display, or became the main display, during the session | The window stays for the rest of the session. The next start tries the display again |
| The virtual display could not be resized | Changing the output size did not resize it | Stop and start mirroring to create it at the new size |

When the display goes offline, is mirrored, or becomes the main display, a recording in
progress is stopped and finalised as the window replaces the display.

The report's `share as a display:` line shows the setting and whether this macOS supports
it. The `screens:` list marks the virtual display with `VIRTUAL SCREEN`.

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
