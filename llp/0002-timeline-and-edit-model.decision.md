# LLP 0002: Timeline and edit model

**Type:** Decision
**Status:** Active
**Systems:** Editor, Timeline
**Author:** Jacob Clausen / Claude
**Date:** 2026-11-12
**Related:** LLP 0000, LLP 0004

Decided by Jacob while building v1 (2026-11-11).

## Rows

Decided by Jacob on 2026-11-13, when images came. Before that every lane was a free "Lane N"
that held effects and texts alike.

The rows are in three groups, and a row holds one kind of thing:

- **The video.** The **Clip**: cuts are clip splits; a split makes a small gap, and you select a
  part and remove it; kept parts can crossfade or fade into each other. Its **Position**: where
  the video sits and how it moves, one track, because the video can only be in one place at a
  time. Its **Effects** lanes: zooms, speed, blur, mono, spotlight, highlight and 3D turns.
- **On top of the video.** **Text** lanes, and one row for each **image** (below).
- **The whole frame.** Lanes for a blur or black and white that covers the whole picture: the
  video, the background and the images. Texts stay sharp on top, so a title reads over a blurred
  picture; "Everything" covers the texts too.

Why: an effect on a lane must say what it changes. A video effect only ever changes the video,
an image's effect only that image, and a whole-frame effect everything. Nobody has to guess.

- The video's Position and Effects rows fold away under the Clip. Each image's rows fold away
  under the image. So the timeline stays short however much is in it.
- Each row has a + that adds its own kind of thing (LLP 0005).
- An empty lane can be removed; one Effects lane always stays.

## Images

- An image is a picture file kept in the recording's folder (`images/`), so a recording stays
  whole when it is copied (LLP 0004).
- Each image is its own row. It works like the video: a block, a **Position** row with its own
  moves, and **Effects** rows with its own effects (blur, black and white, fade, pulse, float,
  wiggle). You learn it once.
- Opening an image's row shows those rows; selecting an image opens it.
- Images are drawn over the video, the top image row in front. Texts are drawn over the images,
  in the order they are listed, as before images came: old recordings look the same.
- Dragging an image in the preview places it. When it already has moves, a drag at another time
  adds a move there, as dragging the video does.

## What may overlap

- Two segments on one lane never overlap.
- Never two zooms, two speeds, two 3D turns, or two of the same visual effect with the same
  reach at one time, even on separate lanes. Texts and images overlap freely.
- On one image: never two of the same effect at one time, and its moves and effects stay inside
  its span.

## Times

Every time in the model is in seconds of the **recording**, not of the edited video. Cuts and
speed don't move your effects. `TimeMap` converts between the two. Templates place things in
video time and convert back, so nothing lands in a removed part.

## Sound

- System sound is recorded by default; a switch under New Recording turns it off. A window
  recording gets its app's sound. Exact Studio's own sound is never recorded.
- The sound is part of the clip. Every cut, speed change, crossfade and fade applies to the sound
  at exactly the same place. There is no separate sound track to keep in sync.
- `volume` (0–1) in `edits.json` sets it; 0 mutes.

## Defaults

- A new recording gets **no** automatic zoom. "Zoom on Clicks" is a button you press.
- Start and end times can be typed in text fields.
- Picking a text animation plays it once in the preview.

## Our own look

The split marker is our own: a thin white line with two arrowheads pointing in. Don't copy a
symbol from another app.
