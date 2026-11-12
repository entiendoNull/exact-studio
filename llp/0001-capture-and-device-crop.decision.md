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

- A window, an area you draw, or a Simulator. Simulator windows are listed under **Simulators**.
- **Area picker**: the selection stays until you confirm it. The rest of the screen is dimmed, and
  a Record / Cancel bar shows next to it.

## Cursor

The system cursor is not recorded in the picture. We record its path and clicks and draw it
ourselves. This lets you hide it, resize it, and squeeze it on click after recording.
