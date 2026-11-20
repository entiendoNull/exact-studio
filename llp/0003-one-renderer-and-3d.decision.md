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

## Shake

Asked for in issue #29 (2026-11-20): a game recording needed a short jolt on each explosion, built by hand from seven moves.

- A shake is an offset and a small turn added to the pose (`Framing.pose` = `steadyPose` + shake), so it works at any place and during a move.
- Its jitter comes from a seed made of its run's first id, never a global random source: preview, export and the CLI draw the same frames, and a split keeps it.
- The zoom's camera and the inspector's Place follow `steadyPose`: a camera on the shaken pose cancelled the shake under a zoom, and a drag saved the jitter.

## Export

- **Export** is a button in the header. It opens a lightbox in the middle of the window, over
  everything. Not in the inspector: it is an action, not a setting.
- Qualities: **Full** (the canvas size, up to 4K), **1080p**, **720p**, **Small** (960 px wide, lower
  bitrate). They only scale down. The frame is drawn at the canvas size, then scaled, so a small
  export looks like the big one.
- Destinations: the Movies folder, **Save As…**, or the **clipboard**. A copy is a real file put
  on the clipboard, so it pastes into Slack, Messages and Finder.
- With unfilled lines (#templates) the lightbox offers no destination. It says how many, lists
  each by time and words, and offers **Show First**: the first is selected and its Words field
  focused. Not a modal: fill it, press Export again. Same check as the CLI (`Edits.unfilled`).

## No blinking

Edits must not make the preview blink. A change swaps the render state and redraws in place. A
rebuild keeps the last frame on screen until the new one is ready.

## One playback at a time

Only a recording that a view shows holds a playback (the player item, its decoders and frames).

- Six hours of use once left 31 playbacks loaded, with 64 sound threads. The main thread waited on
  the media system for half of a 5 s sample while it rebuilt their sound output. The app lagged.
- A second after its last view leaves, an editor lets its playback go and stops watching its files.
- The preview gives each recording a player layer of its own. A layer that had shown another
  recording went blank when that recording's playback was let go.
- The edits, the undo steps and the playhead stay. A view that comes back loads the playback there.
- A change made on disk while it rested shows within a second of coming back.

## The main thread never waits

Opening a recording with many edits once held the main thread for 6 s, and each timeline draw took 0.4 to 0.8 s.

- The player is never asked for its time on the main thread. Its answer waits while a playback
  loads or moves to another layer: up to 3.6 s for each switch between two big edits.
  The editor keeps the playhead itself: a seek sets it at once, and the player's ticks move it while it plays.
- Added sounds that never play together share one audio track; each keeps its volume and fades.
  A track per sound made a recording with 42 sounds take 5.7 s to show a frame, and 6.4 s on the
  main thread to let go.
- A draw asks only cheap questions. Whether a row has a **+** is answered without building its
  menu: building one tries every item in it, to switch off those that would be refused.

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
  placeholders in brackets. A bracketed text is unfilled: `validate` reports it, and `export` and
  the app's Export refuse it, so a placeholder cannot ship by mistake. A rule break does not.
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
