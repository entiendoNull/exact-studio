# LLP 0003: One renderer, and real 3D

**Type:** Decision
**Status:** Active
**Systems:** Renderer, 3D
**Author:** Jacob Clausen / Claude
**Date:** 2026-11-12
**Related:** LLP 0000, LLP 0001, LLP 0004

Decided by Jacob while building v1 (2026-11-11).

## One renderer for everything

The preview, the export and the CLI all draw with the same code (`Framing.render` in a custom
`AVVideoCompositing`). What you see is what you export. Don't add a second, "faster" path for
one of them.

## The stack

A frame is drawn as one list, back to front: background, behind, video, images, texts (`Framing.stack`).
Each reach of a blur or black and white is a cut after one layer (`Framing.cover(_:after:at:)`, by
`Framing.cuts`), so a new reach or a new layer is one entry, not a special case (LLP 0002#where-an-effect-applies).

- The background and the video are drawn per source frame (`render`), so a crossfade blends them;
  the images and texts once over the result (`overlay`). A cut lands on the side its layer is drawn.
- An item behind the video (LLP 0002#depth) is the layer between background and video, drawn in
  `render` (`underlay`) over the covered background, so the `background` cut stays under it and `scene`
  over it. The video's shadow falls on it; it does not zoom with the video.
- It is drawn at the time the items in front are, so both frames of a crossfade show it alike.
- With nothing behind, `underlay` returns the ground as it was: old files render byte for byte the same.

## Export

- **Export** is a button in the header. It opens a lightbox in the middle of the window, over
  everything. Not in the inspector: it is an action, not a setting.
- Qualities: **Full** (the canvas size, up to 4K), **1080p**, **720p**, **Small** (960 px wide, lower
  bitrate). They only scale down. The frame is drawn at the canvas size, then scaled, so a small
  export looks like the big one.
- Destinations: the Movies folder, **Save As…**, or the **clipboard**. A copy is a real file put
  on the clipboard, so it pastes into Slack, Messages and Finder.

## No blinking

Edits must not make the preview blink. A change swaps the render state and redraws in place. A
rebuild keeps the last frame on screen until the new one is ready.

## Real 3D

3D is real 3D (SceneKit), not a 2.5D fake. A 2.5D version was tried and dropped. A device
recording becomes a phone body with thickness, edge material and side buttons, from the
silhouette in LLP 0001. Other recordings become a slab.

- With all angles at 0, 3D looks exactly like the flat picture.
- 3D can be on for the whole video, or only for a while: a **3D Turn** segment on a lane turns
  the video and back, even when 3D is off.

## Templates

Seven templates, each with one purpose: Clean Demo, Hero Angle, Before / After (no text to
write), Feature Spotlight, Social Hook, Tutorial Steps, Product Launch (lines to fill). Reviewed
against the `direct-recording` skill on 2026-11-18; Launch, Hero, Tour and Teaser were retired:
they shipped claims ("Built for speed", "Available now"), stand-ins that read as real copy ("Your
App", "Link in bio"), loops, spins and an orbit that showed the device's back, at fixed shares of
the length whatever happened on screen.

- A template fits the recording: its length as it plays, its clicks (in output time, cut ones
  dropped), its cuts, and the frame's shape. The layout comes from `Framing.layout`, so the text
  sits beside the video when that leaves it larger, else above it.
- The copy never makes a claim. A template writes no text, plain labels ("Before", "After"), or
  placeholders in brackets. A bracketed text is unfilled: `validate` reports it and `export`
  refuses it, so a placeholder cannot ship by mistake.
- Each line gets the reading-speed time of a six-word line: `1.0 s + 0.3 s` a word, never under
  1.5 s, plus 1 s for its animations.
- One emphasis at a time: zooms (1.6×, at least 2.5 s, 1 s apart, one per 8 s at most), the 3D
  turn and texts never overlap. A blur only sits under the opening title.
- Texts share one placement, weight, style and calm animation, and their colour follows the
  background (black on light, white on dark). A title over the blurred opening sits on a pill,
  since the blur can be light or dark.
- A template keeps the cuts, speed changes, transitions, 3D settings, images, masks and sounds, and
  is one undo step.

## Demos

Demo edits avoid speed changes (they look like lag), start flat like a normal screen recording
and save 3D for later, and keep texts and zooms apart.

## Regression check

Rendering is deterministic. Five reference frames are rendered and compared byte for byte (md5)
before and after renderer changes. A change in the hash must be on purpose.
