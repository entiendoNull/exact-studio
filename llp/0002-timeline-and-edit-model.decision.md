# LLP 0002: Timeline and edit model

**Type:** Decision
**Status:** Active
**Systems:** Editor, Timeline
**Author:** Jacob Clausen / Claude
**Date:** 2026-11-12
**Related:** LLP 0000, LLP 0004

Decided by Jacob while building v1 (2026-11-11).

## Rows

Decided by Jacob on 2026-11-13, when images came; rows from use and the stack of layers on 2026-11-18.
Before images every lane was a free "Lane N" that held effects and texts alike.

A row holds one kind of thing, and **a row exists only while it holds something**:

- **The Video.** The **Clip**: cuts are clip splits; a split makes a small gap, and you select a part and
  remove it; kept parts can crossfade or fade into each other. Its recorded sound is a band along the
  Clip's bottom, cut with it (see Sound). Under it, indented: its **Moves** row (where the video sits and
  how it moves, one track, because the video can only be in one place at a time) and its **Effects**
  rows: zooms, speed, blur, mono, spotlight, highlight, 3D turns and masks (LLP 0006), and a blur or black
  and white of any reach (see Where an effect applies).
- **Text** and **Images** rows, in front of the video or behind it: they are the stack (LLP 0005#layers).
- **Music & Sound.** Rows for the sounds you add: heard, not drawn, so under the stack (see Sound).

- Names are plain: Effects, Text, Images, Music & Sound. A second row of a kind adds a number: "Text 2".
- **Lanes come from use.** The app writes each count as the number of lanes in use and drops an empty
  lane; the others close up in order. A count may be 0. A new recording shows the Clip alone.
- **A second row of a kind opens for an overlap.** An item that meets another of its kind goes to the
  first lane with room, else a new one. An effect or sound dropped where a lane above has room goes up to it,
  so a lane of effects holds what overlaps and no more. A text or an image stays on the row it is dropped on:
  its row is its place in the stack.
- View ▸ Show Empty Lanes shows one empty row of each kind as a target. It is a view setting, never in
  `edits.json`.
- Why: an empty lane is clutter, for a person and for an agent. Rows that appear with what they hold
  explain themselves.
- Each row has a + that adds its own kind of thing (LLP 0005).
- A lane can be deleted with what it holds, after asking; no lane has to stay (LLP 0005).

## Images

- An image is a picture file kept in the recording's folder (`images/`), so a recording stays
  whole when it is copied (LLP 0004).
- An image works like the video: a block, a **Moves** row with its own moves, and **Effects**
  rows with its own effects (blur, black and white, fade, pulse, float, wiggle). You learn it once.
- Images sit on **image lanes**, as texts sit on text lanes. Images in sequence share a lane;
  images at the same time go on separate lanes. A new image takes the first lane free at its time.
- An open lane shows one image's Moves and Effects rows at a time: the selected image, else the
  one on the lane selected last, else the one under the playhead. Those rows are lit only across
  that image's time, and its block has a thin outline. Selecting an image opens its lane.
- Images and texts are drawn in the order of their rows (see Depth); a file from before draws as it did.
- Decided by Jacob on 2026-11-13. At first each image was its own row. That did not scale: ten
  logos in a row made ten rows, and it was not what a lane means anywhere else.
- A file from before `imageLanes` may have two images at once on one lane: each then gets a lane of its own,
  so it stacks as before.
- Dragging an image in the preview places it. When it already has moves, a drag at another time
  adds a move there, as dragging the video does.

## What may overlap

- Two segments on one lane never overlap.
- Never two zooms, two speeds, two 3D turns, or two of the same visual effect at one time, even on
  separate lanes. Texts, images and masks on separate lanes overlap freely.
- On one image or one text: never two of the same effect at one time, and its moves and effects
  stay inside its span.

Decided by Jacob on 2026-11-18, with the rules table (docs/edits.md, "What may overlap: the rules"):

- **Every rule has an id and two lines.** Line 1 names the rule in five words or fewer; line 2 names
  the other item or time and one way out. `Edits.conflicts` returns them as a value (`Conflict`:
  rule, item, other, line 1, line 2), so the app, `validate` and MCP say the same words (LLP 0005).
  The value names items, not lanes or rows, so later lane and row changes keep it.
- **P1, `move-after-move`.** A move starts travelling only after the move before it lands, for the
  video and for each image. Why: `Framing.movedPose` let a later move that started early jump to its
  own progress the moment the earlier one landed.
- **`move-in-crossfade`.** A video move does not travel while a crossfade blends. Each side of the blend
  draws the video at its own time, so a move there showed it twice; a dissolve showing both shots stays.
- **P2, `one-blur` and `one-mono`.** One blur at a time and one black and white at a time, whatever
  each covers. Why: a video blur under a whole-frame blur blurred the video twice. The clash group
  no longer counts `scope`; the lanes still do.
- **P4, `no-zoom-in-orbit`.** No zoom during a 3D orbit. Why: half way the screen faces away, and a
  zoom follows the cursor on a screen that is not there.
- **A taken lane is not a refusal in the app.** A drop or a change that lands an item on a taken lane
  puts it on the first free lane of its kind, or a new one. In a file, `validate` still reports
  `lane-taken`.
- **Old files are never lost.** A file that breaks a rule (one written before P1, P2 or P4) opens,
  plays and exports as before. `validate` reports it and the app marks the items; only a change that
  breaks a rule anew is refused. A break is new when its pair (rule, item, other) was not broken
  before the change. So a file with a video blur under a whole-frame blur keeps both, either may
  still be moved or changed, and a third blur over them is refused.
- A text's own effects follow the image's rules under their own ids: `text-one-each`,
  `text-inside`, `text-effect-kind` ("One of each per text.", "Keep it inside the text.").
- Depth (`layer`, `order`) breaks no rule: arranging changes no time or lane.
- Taste (a spotlight with a zoom, zooms back to back) stays advice in docs/effects.md and the
  directing skill; the app never refuses it.

## Where an effect applies

Decided by Jacob on 2026-11-18 (option A of the "where an effect applies" review). Before, a blur
or black and white reached the video, the frame under the texts, or everything.

- A frame is a fixed stack, back to front: background, behind the video, video, images, texts (see
  Depth). A blur's or black and white's `scope` is a cut in it and covers every layer under the cut:
  `background`, `scene` (background, the items behind and video), `frame` (and the images), `all`. No `scope` is the video alone, on its own
  pixels, as before. Old files do not change.
- One item alone takes its own effect: a text has `effects` as an image does (blur, black and white,
  fade), on its own Effects row under its lane, with the same per-item rules. Its block shows a chip.
- The inspector draws "Applies to" as that stack with a line to drag (LLP 0005). The blur stays a block on
  an Effects row, whatever it covers; its caption says its reach ("Blur · video, background"). A file's
  `frameLanes` (whole-frame lanes, before) is read once: their items move to the first effect lane with
  room, and the picture does not change.
- Spotlight and cursor highlight have no reach: they follow the cursor on the video.
- Why the inspector and not the rows: a reach is one word an agent writes, and it covers whole layers. Covering one image lane but not another is not possible; use the item's own effect.

## Depth

Asked for by Jacob on 2026-11-18: "the same z-index idea is good for pretty much any element", so
texts and images can appear from behind the video. The same day the rows became the stack (LLP 0005#layers).

- The stack, front to back: the text and image rows in front, the video, the rows behind the video, the
  background. `layers` in `edits.json` lists the rows front to back (`"text:0"`, `"image:1"`, `"video"`);
  each kind's lanes are numbered from its front row.
- An item's `layer` (`"behind"`, or none: in front) says which side of the video its row is on. The app
  writes both. A file's item whose `layer` names the other side moves to a row there.
- A file without `layers` is read in the order it drew before: images by `order`, then lane, 0 in front;
  texts over them by `order`, then their place in the list, a later one in front. Each item gets a row in
  front of every row it drew over, so old files draw as before. `order` is not written again.
- A `frame` reach covers up to the front-most image row; `all` covers everything (see Where an effect applies).
- Arrange is the familiar set: Bring Forward, Send Backward, Bring to Front, Send to Back, Send Behind
  Video, Bring In Front of Video. Forward and backward put the item on a row just past the next row that
  shows with it; front and back to the end of its side. Across the video it lands next to it, on its kind's
  row there when that has room. The other items of its old row stay.
- A split item moves with its halves. Each step is one undo step, named for it.

## Times

Every time in the model is in seconds of the **recording**, not of the edited video. Cuts and
speed don't move your effects. `TimeMap` converts between the two. Templates place things in
video time and convert back, so nothing lands in a removed part.

## Sound

- System sound is recorded by default; a switch under New Recording turns it off. A window
  recording gets its app's sound. Exact Studio's own sound is never recorded.
- The recorded sound is part of the clip. Every cut, speed change, crossfade and fade applies to
  it at exactly the same place. There is no separate sound track to keep in sync.
- It is drawn inside the Clip, as a waveform band along its bottom, so you see that it is cut with the
  clip. A click on the band selects it: Mute and Volume. A recording with no sound has no band. `volume` (0–1) in `edits.json` sets it; 0 mutes.

Decided by Jacob on 2026-11-20 (issue #25):

- The recorded sound comes from `capture.mov`, or from a file named in `edits.json` (`recordedSound`:
  a file in `sounds/` and an `offset`; recording time t plays file time t + offset, silence outside the file).
- Why: a sound recorded outside the app, and the Simulator app's sound (issue #26), must follow the cuts.
- One recorded sound keeps the timeline to one kind of sound that follows the cuts. A sound you add never does.
- `capture.mov` is never rewritten: putting sound into it broke seeking in its HEVC video.
- The band draws the file's sound; its inspector names the file, and Use Captured Sound goes back.

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
