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

The rows are in four groups, and a row holds one kind of thing:

- **The video.** The **Clip**: cuts are clip splits; a split makes a small gap, and you select a
  part and remove it; kept parts can crossfade or fade into each other. Its **Sound**, when it has
  one: the recorded sound's waveform, with the removed parts dimmed (see Sound). Its **Position**: where
  the video sits and how it moves, one track, because the video can only be in one place at a
  time. Its **Effects** lanes: zooms, speed, blur, mono, spotlight, highlight, 3D turns and masks
  (LLP 0006).
- **On top of the video.** **Text** lanes, then **Image** lanes (below).
- **Sound.** Lanes for the sounds you add: music on one, short sounds on another (see Sound).
- **The whole frame.** Lanes for a blur or black and white that reaches past the video: the
  background only, the background and the video, those and the images, or everything (see
  Where an effect applies). So a title reads over a blurred picture.

Why: an effect on a lane must say what it changes. A video effect only ever changes the video,
an image's effect only that image, and a whole-frame effect everything. Nobody has to guess.

- The video's Sound, Position and Effects rows fold away under the Clip. An image's own rows fold
  away under its lane. So the timeline stays short however much is in it.
- Each row has a + that adds its own kind of thing (LLP 0005).
- A lane can be deleted with what it holds, after asking; one Effects lane always stays (LLP 0005).

## Images

- An image is a picture file kept in the recording's folder (`images/`), so a recording stays
  whole when it is copied (LLP 0004).
- An image works like the video: a block, a **Position** row with its own moves, and **Effects**
  rows with its own effects (blur, black and white, fade, pulse, float, wiggle). You learn it once.
- Images sit on **image lanes**, as texts sit on text lanes. Images in sequence share a lane;
  images at the same time go on separate lanes. A new image takes the first lane free at its time.
- An open lane shows one image's Position and Effects rows at a time: the selected image, else the
  one on the lane selected last, else the one under the playhead. Those rows are lit only across
  that image's time, and its block has a thin outline. Selecting an image opens its lane.
- Images are drawn over the video, the top lane in front. Texts are drawn over the images,
  in the order they are listed, as before images came: old recordings look the same.
- Decided by Jacob on 2026-11-13. At first each image was its own row. That did not scale: ten
  logos in a row made ten rows, and it was not what a lane means anywhere else.
- A file from before has no `imageLanes`. Each of its images keeps the lane it had, so it stacks as before.
- Dragging an image in the preview places it. When it already has moves, a drag at another time
  adds a move there, as dragging the video does.

## What may overlap

- Two segments on one lane never overlap.
- Never two zooms, two speeds, two 3D turns, or two of the same visual effect with the same
  reach at one time, even on separate lanes. Texts, images and masks on separate lanes overlap freely.
- On one image or one text: never two of the same effect at one time, and its moves and effects
  stay inside its span.

## Where an effect applies

Decided by Jacob on 2026-11-18 (option A of the "where an effect applies" review). Before, a blur
or black and white reached the video, the frame under the texts, or everything.

- A frame is a fixed stack, back to front: background, video, images, texts. A blur's or black and
  white's `scope` is a cut in it and covers every layer under the cut: `background`, `scene`
  (background and video), `frame` (and the images), `all`. No `scope` is the video alone, on its own
  pixels, as before. Old files do not change.
- One item alone takes its own effect: a text has `effects` as an image does (blur, black and white,
  fade), on its own Effects row under its lane, with the same per-item rules. Its block shows a chip.
- The inspector draws "Applies to" as that stack with a line to drag (LLP 0005). The timeline keeps
  its fixed kind order; a block's caption says its reach ("Blur · video, background").
- Spotlight and cursor highlight have no reach: they follow the cursor on the video.
- Why the inspector and not the rows: rows from use and the fixed kind order stay, and a reach is
  one word an agent writes. Covering one image lane but not another is not possible; use the item's own effect.

## Times

Every time in the model is in seconds of the **recording**, not of the edited video. Cuts and
speed don't move your effects. `TimeMap` converts between the two. Templates place things in
video time and convert back, so nothing lands in a removed part.

## Sound

- System sound is recorded by default; a switch under New Recording turns it off. A window
  recording gets its app's sound. Exact Studio's own sound is never recorded.
- The recorded sound is part of the clip. Every cut, speed change, crossfade and fade applies to
  it at exactly the same place. There is no separate sound track to keep in sync.
- It has its own row under the Clip, so you see that it is cut with the clip. Selecting the row
  shows Mute and Volume. `volume` (0–1) in `edits.json` sets it; 0 mutes.

Decided by Jacob on 2026-11-13, when added sounds came:

- You can add music and other sounds from files. A sound file is kept in the recording's folder
  (`sounds/`), as a picture is (LLP 0004).
- **An added sound is not cut, sped up or slowed by the video's cuts and speed changes.** Only its
  `start` is in recording time, so it stays with its moment when you cut earlier parts. From there
  it plays straight through, in video time, for `length` seconds or until the video ends.
- Why: music that jumps at every cut sounds wrong. The recorded sound is the one that follows the cuts.
- So on the timeline a sound's block starts at its start and ends where its length runs out in the
  video. A start in a removed part plays from the next kept moment.
- Two sounds on one lane never play at once. Each has its own volume and fades.

## Split

Decided by Jacob on 2026-11-18. Before, "Split Here" cut a block with no join: a split zoom dipped
to 1×, a split text played its exit and entrance at the cut.

- **Every split keeps the video the same.** Split only makes two blocks you can change apart.
- A split marks the halves: the first gets `joinEnd`, the second `joinStart`. The second keeps the
  first's settings and gets a fresh id (`z1` → `z1-2`). Old files have no joins; a missing key is not joined.
- Two blocks are joined while both say so, they are the same kind on the same lane, and the second
  starts where the first ends. A sound must also be the same file and start where the first stops in the video.
- The renderer draws a joined run as one block: eases, a text's entrance and exit, a 3D turn and
  an orbit use the whole run's start and end. Only the half under the playhead draws, with its own
  settings. So a text's loop keeps its phase, and a zoom stays in.
- An image's halves share their moves and effects: each half keeps those that land in its time,
  and the run plays them all. Its own effects that cross the cut split and join too.
- A split sound plays on from the same moment of its file (`offset`); it fades in at the run's
  start and out at its end, never where the halves meet.
- A mask never fades, but where its halves meet it drops the few milliseconds of slack at each end,
  so it is never drawn twice.
- **A join breaks when the halves stop touching.** Move or resize one away, put it on another lane
  or make it another kind, and the app drops both marks on the next change. Each half then eases
  and animates on its own, as any block does. `validate` reports a mark without its partner.
- Moves are points in time (a landing and a travel before it). They are never cut.
- Speed has no ease, so a split speed changes nothing; it is still marked.
- On the timeline a joined edge is square: the block goes on.

## Undo

Asked for by Jacob on 2026-11-18. Before, only a template could be taken back.

- Every change to the edit, the look or the crop is one step: a split (named "Split Text", "Split All Lanes"…), an add, a remove, a drag,
  an inspector setting, a template, Clear Edits, Find a Device.
- ⌘Z undoes, ⇧⌘Z and ⌘Y redo. Edit ▸ Undo names the step ("Undo Split Clip"); so do the two
  arrow buttons beside Play.
- A drag is one step: it saves on the drop. A slider scrub or a run of scrolls over the preview is
  one step too: changes to the same setting of the same thing less than a second apart are one.
- Each recording has its own history while the app runs. It is not saved.
- A change an agent or the CLI makes to the files is one step, "Edit from File". Undoing it
  writes the files back, so the agent sees it.
- While a text field has the focus, ⌘Z is the field's own.
- Selection, zoom and playback are not steps.
- A device's old silhouette file stays in the folder, so undoing Find a Device or Not a Device
  brings it back.

## Defaults

- A new recording gets **no** automatic zoom. "Zoom on Clicks" is a button you press.
- Start and end times can be typed in text fields.
- Picking a text animation plays it once in the preview.

## Our own look

The split marker is our own: a thin white line with two arrowheads pointing in. Don't copy a
symbol from another app.
