# LLP 0001: Capture and the device crop

**Type:** Decision
**Status:** Active
**Systems:** Capture
**Author:** Jacob Clausen / Claude
**Date:** 2026-11-12
**Related:** LLP 0000

Decided by Jacob while building v1 (2026-11-11).

## The crop is the phone, exactly

This is the reason the app exists. A Simulator recording shows the phone and nothing else: no
window, no toolbar, no background in the corners. Other recorders always get a bit more. Don't
"simplify" toward a rectangle.

- The crop follows the phone's real outline, so round corners stay round.
- The side buttons are part of the phone. Keep them.
- Corners outside the phone must not show another color.

## How the phone is found

Three ways, in order, because no single one works for all windows:

1. **Alpha**: the window is transparent around the phone.
2. **Dark outline**: an opaque window (like Device Hub) with a dark bezel.
3. **Silhouette**: a flood fill from the edges gives a mask of the phone, buttons and all. It is
   saved as `mask-*.png` beside the recording. `Bezel.body()` reads the main body, the corner
   radius and the buttons from it. The 3D view uses those too (LLP 0003).

The silhouette is found off the capture queue, at about frame 10, so recording never stalls.

## Sources

Asked for by Jacob on 2026-11-13: four sources, each picked on the screen.

- **Display**, **Window**, **Area** and **Simulator** are four equal buttons in the New Recording card.
- Each opens a picker over every display. The pickers share one look: the screen dimmed a little,
  the candidate under the pointer lit with an outline, a hint at the bottom, Escape or a right-click
  to cancel.
- The lit candidate shows its app's icon, its name, its size and a **Start Recording** button.
- Only that button, or Return, starts a recording. A click on the screen only lights a candidate.
  A stray click must never start a recording.
- A card that does not fit inside a small candidate sits just below it, else above it.
- **Display picker**: with one display, it is lit at once.
- **Window picker**: other apps' windows, never Simulator or emulator windows, and never ours.
- **Simulator picker**: only Simulator and emulator windows. It lights the phone, not the window:
  one screenshot of the window goes through the same bezel finder as a recording. Until that
  lands, or if it finds nothing, the whole window is lit.
- With no Simulator or emulator open, there is no overlay; the card says to open one.
- **Area picker**: the selection stays until you confirm it, with a Start Recording / Cancel bar
  beside it.
- The Displays and Windows lists are gone; the pickers replace them.
- The **Simulators** list stays: one click on a named device records it. That is the main use.

## Menu bar

- An Exact Studio mark sits in the menu bar while the app runs: a rounded frame around a dot.
- Its menu starts each picker, switches System Sound, opens the window, or quits.
- While recording, the mark turns red with the time. One click stops; no menu is in the way.
- System Sound is one setting, kept by the native module. The sidebar switch and the menu item
  both change it.
- A start from the menu that fails brings the window forward, where the card shows why.
- Under the agent there is no menu bar item.

## Windows keep their own shape

A window is captured on its own, without its shadow, so its rounded corners come out transparent.
That alpha is the cut: the video follows the window's real outline, whatever its corner radius.
The frame's own corner setting does not apply to a window.

- The radius is measured once from the alpha (the corner's reach down the side and along the top)
  and kept in `meta.json` as `cornerRadius`. 3D uses it for the window's body.
- An older window recording gets its radius measured when it is opened.
- "Find a Device" on a window recording makes it a device recording instead.

## Cursor

The system cursor is not recorded in the picture. We record its path and clicks and draw it
ourselves. This lets you hide it, resize it, and squeeze it on click after recording.
