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

## Export

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

Each frame shape (16:9, 9:16, 1:1, 4:3) has its own versions of the templates (launch, hero,
tour, teaser): texts, effects, zooms and moves laid out so texts stay clear of the video. A
template keeps your cuts and can be undone once.

## Demos

Demo edits avoid speed changes (they look like lag), start flat like a normal screen recording
and save 3D for later, and keep texts and zooms apart.

## Regression check

Rendering is deterministic. Five reference frames are rendered and compared byte for byte (md5)
before and after renderer changes. A change in the hash must be on purpose.
