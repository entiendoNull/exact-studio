# Editing recordings as files

Every recording is a folder of plain files. An agent (or a person with an editor) can change the
edit by rewriting two JSON files, check it, render a frame to look at, and export, without the
app's UI. The app watches the files: a change shows in its open preview within a second.

```
~/Movies/Exact Studio/Recordings/<id>/
├── capture.mov     the raw recording (HEVC with alpha); never edited
├── meta.json       what the capture found: size, crop, clicks, silhouette; rarely edited
├── cursor.json     the cursor's path; never edited
├── mask-*.png      a device's silhouette, if one was found
├── images/         the pictures the edit puts on the video; `exact-studio image` copies them here
├── sounds/         the music and sounds the edit plays over the video; `exact-studio sound` copies them here
├── edits.json      the timeline: cuts, transitions, effects, masks, texts, images, sounds, zooms, speed, moves, 3D
└── look.json       the frame: background, shape, padding, corners, shadow, cursor
```

JSON Schemas: [`schema/edits.schema.json`](../schema/edits.schema.json), [`schema/look.schema.json`](../schema/look.schema.json).

This file is the format. [`docs/effects.md`](effects.md) is what each effect, move style, text and image
animation, style and transition looks like on screen, its timing and its limits, with picture strips:
read an entry before you use a thing for the first time.

## The loop

```sh
./exact-studio list                      # ids, newest first
./exact-studio show latest               # parts, segments, moves and look, in readable form
./exact-studio image latest logo.png --at 2 --for 6   # a picture on top of the video; prints the new segment
./exact-studio sound latest music.m4a --at 0          # music over the video; prints the new sound
./exact-studio frame latest 2 --raw                   # .exact/frame.png: the full recorded frame, to measure a mask on
./exact-studio mask latest --rect 0.1,0.2,0.3,0.05 --at 2 --for 6   # hide that part; prints the new segment
# …edit edits.json / look.json…
./exact-studio split latest 4.2 t1                    # cut text t1 at 4.2 s into two joined halves
./exact-studio split latest 4.2 --all                 # Split All Lanes: the clip and every block at 4.2 s
./exact-studio validate latest           # exit 1 with one line per problem; a broken rule: its id and two lines
./exact-studio frame latest 4.5          # .exact/frame.png: the frame at 4.5 s of the video
./exact-studio export latest             # ~/Movies/Exact Studio/<name> <id>.mp4
./exact-studio export latest --quality 720p   # best (default), 1080p, 720p or small
```

`frame` and `export` use the app's own renderer, so what they show is what the app exports.
`--library <dir>` (or `EXACT_STUDIO_LIBRARY`) points at another Recordings folder.

## Time

**Every time in `edits.json` is in seconds of the recording** (`capture.mov`), not of the video as it
plays. Cuts and speed changes make the two differ: `show` prints both lengths, and
`frame <id> <t>` takes video time (`--source` for recording time) and prints the other.
`--raw` renders the full recorded frame at that time instead, before the crop and with no edits (see [Masks](#masks)).

## edits.json

```json
{
  "splits": [4.2, 7.0],
  "removed": [0, 7.0],
  "transitions": { "4200": "crossfade" },
  "base": { "x": 0.5, "y": 0.5, "scale": 1 },
  "moves": [],
  "three": { "on": false, "tilt": 0, "turn": 0, "roll": 0, "thickness": 0.06, "edge": "metal" },
  "volume": 1,
  "sounds": [
    { "id": "sound1", "file": "sounds/music.m4a", "lane": 0, "start": 0, "length": 18,
      "offset": 0, "volume": 0.4, "fadeIn": 0, "fadeOut": 1.5 }
  ],
  "segments": [
    { "id": "t1", "kind": "text", "start": 4.3, "end": 7.0, "lane": 0, "text": "Hello", "x": 0.5, "y": 0.15,
      "size": 0.08, "color": "white", "weight": "heavy", "style": "pill", "animIn": "letters", "animOut": "fade" },
    { "id": "z1", "kind": "zoom", "start": 8.0, "end": 11.0, "lane": 0, "level": 1.6 }
  ]
}
```

Every key is optional; a missing one takes its default. Inside a segment, a sound or a move, only
the keys named as required are needed; every other key there takes its default too.

**A file that can't be read is never written over.** When `edits.json` or `look.json` is not
valid JSON, or a value has the wrong type, the app opens the recording without it, says why in the
inspector, and saves nothing over that file until it is fixed; it reads the fixed file within a
second. The CLI does the same: every verb but `validate` stops with exit 1 and writes nothing, and
`validate` says why. A missing file is no problem: the recording starts clean.

### Cutting: `splits`, `removed`, `transitions`

The clip is cut at each time in `splits` (sorted). That makes parts: 0 to the first split, split to
split, the last split to the end. A part is left out of the video when its **start** is in
`removed` (0 for the first part). Where removed parts lie between two kept parts, `transitions`
says how the video passes from one to the next, keyed by the earlier kept part's **end in
milliseconds**, as a string: `"crossfade"` (0.6 s, less when a part lasts under 1.2 s; the video gets that much
shorter) or `"fade"` (0.4 s out and 0.4 s in, through the background). No key is a plain cut.

To cut out 10–14 s: add `10` and `14` to `splits`, `10` to `removed`.

To keep only 9–14 s and 49–53 s: `splits` is `[9, 14, 49, 53]` and `removed` is `[0, 14, 53]`.
The part after the last split is kept unless its start is in `removed`. Here that is `53`; without
it the video keeps everything from 53 s to the end. `validate` adds a note when the first part is
removed and the last part is kept after a gap, and `show` lists every part.

The recorded sound, if any, follows the picture: it is cut, sped up and faded at the same places.
`volume` (0–1, default 1) sets how loud it is; 0 mutes it. Sounds you add are different: see
[Sounds](#sounds).

### Segments

Each has an `id` (any unique string without a colon), `kind`, `start`, `end` (at least 0.1 s apart),
all required, and `lane` (0 up, default 0). A segment's kind decides which rows its `lane` counts:

| what | kinds | its `lane` counts |
|---|---|---|
| an effect | `zoom`, `speed`, `spotlight`, `highlight`, `3d`, `mask`, `blur`, `mono` (a blur or black and white of any `scope`) | the effect lanes, the Video's Effects rows |
| a text | `text` | the text lanes, 0 the front one |
| an image | `image` | the image lanes, 0 the front one |

An effect on the video never touches a text or an image, and an image's or a text's own effects
(below) never touch anything else. What may overlap is in [the rules](#what-may-overlap-the-rules).
**For texts and images, lane order is draw order:** their rows are one stack with the video among them
(see [Depth](#depth-layers-and-layer)).

**Lanes come from use.** Put each item on lane 0 of its kind; use lane 1 only when it overlaps another of
its kind in time, and so on. Leave the counts (`lanes`, `textLanes`, `imageLanes`, `soundLanes`) out:
the app writes them as the number of lanes in use, and drops a lane that is empty, the others closing up
in order. A count may be 0. `validate` notes a count that differs from the lanes in use, and never fails on it.

Files from before:

- `frameLanes` is read from old files only, never written. Their whole-frame blurs and black-and-whites
  (a `scope` past the video) had lanes of their own; each moves to the first effect lane with room, and
  the picture does not change.
- A file with no `textLanes` is an old one, where texts shared the effect lanes: each kind's lanes close
  up on their own when it is read.
- A file with two images at once on one lane and no `imageLanes` is an old one, where each image had a
  row of its own: each image gets a lane of its own, so the picture stacks as before.

| kind | fields | |
|---|---|---|
| `zoom` | `level` | above 1 zooms in toward the cursor (1.5–3 is usual), below 1 zooms out (0.5–0.85); eases in and out over 0.7 s (half its length when shorter) |
| `speed` | `rate` | 0.25–8; 0.5 is half speed |
| `spotlight` | | darkens all but a circle around the cursor |
| `highlight` | | a soft glow under the cursor |
| `blur` | `scope` | how far down the stack it reaches; see [Where an effect applies](#where-an-effect-applies). None: only the video |
| `mono` | `scope` | black and white, the same reaches |
| `3d` | `tilt`, `turn`, `roll`, `style` | turns the video in 3D over its span and back, even with 3D off, easing over 0.7 s (a third of a short span); `style` `"hold"` (the default: holds `tilt`, `turn`, `roll`, default 10, −24, 0) or `"orbit"` (one full turn about the vertical across the whole span; `turn` is ignored) |
| `mask` | `rect`, `style`, `color`, `radius` | hides a part of the recording; see [Masks](#masks) |
| `text` | see below | |
| `image` | see below | |

**Text fields:** `text` (the words); `x`, `y` (its centre, 0–1 of the frame, top-left origin);
`size` (its font size as a share of the frame's height, default 0.08; 0.04–0.12 is usual); `color` (`white`, the default, `black`, `yellow`,
`pink`, `blue`, `mint`); `weight` (`regular`, `bold`, the default, `heavy`, `rounded`); `style` (`plain`, the default, `pill`, `box`,
`outline`, `shadow`); `animIn` (default `pop`; `letters`, `letters-pop`, `drop`, `typewriter`, `pop`, `spin`, `slide`, `rise`,
`blur`, `fade`, `none`); `animOut` (`fade`, the default, `fall`, `letters`, `pop`, `sink`, `blur`, `none`); `loop` while
shown (`none`, `wave`, `pulse`, `float`, `wiggle`); `rotation` (degrees); `effects`, its own (below); `layer`,
the side of the video its row is on (see [Depth](#depth-layers-and-layer)).

Keep a text clear of the video: put it beside the video when the frame is wide, above or below it
when tall, and not where a zoom pulls the video under it.

**A text's own effects, `effects`:** as an image's (see [Images](#images)): each has an `id`, `kind`,
`start`, `end` (inside the text's span) and `lane` (its row under the text). Kinds: `blur`, `mono` and
`fade` (to `level`, default 0.3). They ease in and out over 0.3 s and touch only this text. Two effects on one
`lane` must not overlap, nor two of the same kind on any lane.

```json
{ "id": "t1", "kind": "text", "start": 1, "end": 6, "lane": 0, "text": "Meet Exact",
  "effects": [ { "id": "tb", "kind": "blur", "start": 4, "end": 5.5 } ] }
```

### Where an effect applies

A frame is a stack, back to front: the **background**, the rows **behind the video**, the **video**, the
rows in front (see [Depth](#depth-layers-and-layer)). A `blur` or `mono` segment's `scope` is a cut in
that stack: it covers every layer under the cut. It sits on the effect lanes, whatever its reach.

| `scope` | covers | stays as it is |
|---|---|---|
| none (or `"video"`) | the video only, on its own pixels, with its other effects | the background, images, texts |
| `"background"` | the background | the items behind the video, the video, images, texts |
| `"scene"` | the background, the items behind the video and the video | images, texts |
| `"frame"` | the background, the video, and the rows in front up to the front-most image row | the rows in front of that |
| `"all"` | everything | nothing |

One image or one text alone: give that item its own `blur` or `mono` in its `effects`. Spotlight and
cursor highlight have no `scope`: they follow the cursor on the video. Files from before have none
of the new values, so they draw as they did.

### Depth: `layers` and `layer`

A frame is one stack, front to back: the text and image rows in front of the video, the **video**, the
rows **behind the video**, the **background**. Each text lane and each image lane is one row, and **the
rows are the draw order**: an image row may sit over a text row. On the timeline they are the rows above
the Video and under it, as in a layers panel.

| field | values | |
|---|---|---|
| `layers` (top level) | the rows front to back: `"text:0"`, `"image:0"`, …, and `"video"` once | where each row sits; a row above `"video"` is in front of it |
| `layer` (a text's or an image's) | `"front"` (the default), `"behind"` | the side of the video its row is on |

```json
{ "layers": ["text:0", "image:0", "video", "image:1"],
  "segments": [
    { "id": "t1", "kind": "text", "start": 1, "end": 4, "lane": 0, "text": "Meet Exact" },
    { "id": "logo", "kind": "image", "start": 1, "end": 8, "lane": 0, "file": "images/logo.png" },
    { "id": "back", "kind": "image", "start": 1, "end": 8, "lane": 1, "file": "images/glow.png", "layer": "behind" }
  ] }
```

- The app writes `layers`, each kind's lanes numbered from its front row, and every item's `layer` to
  match its row. You may leave `layers` out: a new row of texts goes in front of everything, a new row
  of images behind the images in front, anything behind the video just under it.
- An item whose `layer` names the other side of the video from its row moves to a row on that side.
- A file without `layers` draws as it did before rows were the stack: images by `order`, then lane,
  0 in front; texts over them by `order`, then their place in `segments`, a later one in front. The app
  turns that into rows when it reads the file; `order` is read, never written again.
- An item behind the video is hidden where the video covers it, and shows where the video moves, shrinks,
  turns in 3D or is cropped away. It does not zoom with the video.
- A `background` reach stays under it; `scene`, `frame` and `all` cover it (see [Where an effect applies](#where-an-effect-applies)).
- Its own animations, moves and effects play as in front.
- Use it for a logo or a title that a move of the video reveals. Never put a key point behind the video.

In the app, drag a row by its label to move it in the stack, past the Video too. Edit ▸ Bring Forward,
Send Backward, Bring to Front, Send to Back, Send Behind Video and Bring In Front of Video (also in the
item's ⋯) move one item: forward and backward to a row just past the next row that shows with it.

### Splits and joins: `joinStart`, `joinEnd`

A split cuts a block in two so each half can be changed on its own. **It never changes the video.**
The halves are marked: the first gets `"joinEnd": true`, the second `"joinStart": true`, and the
second gets a fresh id (`z1` → `z1-2`). Segments, an image's or a text's own effects and sounds take the two
keys; a missing key is not joined.

```sh
./exact-studio split <id> <t>                 # the clip, at <t> seconds of the recording
./exact-studio split <id> <t> <item>          # a segment or a sound by id; an image's or a text's effect as <item>:<effect>
./exact-studio split <id> <t> --all           # the clip and every block under <t>; moves are never cut
```

Each half must last at least 0.1 s. Two blocks are joined while both say so, they are the same
`kind` on the same `lane`, and the second starts where the first ends (a sound: the same `file`,
starting where the first stops in the video). Then they draw as one:

- Nothing eases where they meet: a zoom stays in, a blur stays on, a 3D turn stays turned.
- A text has no exit and no entrance there, and its loop keeps its phase. Change the second half's
  `text` to swap the words in place.
- An image's halves share their `moves` and `effects`: each lands in or covers its own time, and the
  run plays them all as one image. An effect that crosses the cut is split and joined too.
- A sound's second half plays on from the same moment of its file: its `offset` is the first's
  `offset` + `length`. It fades in at the first half's start and out at the last half's end.
- Each half keeps its own settings, so a changed level, colour or volume shows from the cut on.

Move a half away, resize it so they no longer touch, or put it on another lane, and the join is
gone: the app drops both keys, and each half eases and animates on its own again. `validate`
reports a key without its partner.

### Images

An image is a picture on top of the video: a logo, a badge, a screenshot, a sticker. Its file lives
in the recording's folder, so the recording stays whole when it is copied.

```sh
./exact-studio image <id> ~/Desktop/logo.png --at 2 --for 6
```

copies the picture to `images/logo.png`, adds this segment at 2 s of the recording for 6 s, on the
first image lane free then (else a new one), and prints it. Then edit the segment like any other:

```json
{ "id": "image1", "kind": "image", "start": 2, "end": 8, "lane": 0, "file": "images/logo.png",
  "x": 0.2, "y": 0.2, "size": 0.18, "rotation": 0, "opacity": 1, "radius": 0.2, "shadow": true,
  "animIn": "pop", "animOut": "fade",
  "moves": [
    { "id": "m1", "t": 5, "to": { "x": 0.85, "y": 0.15, "scale": 0.6 }, "style": "smooth", "duration": 1 }
  ],
  "effects": [
    { "id": "e1", "kind": "pulse", "start": 2.5, "end": 4, "lane": 0 },
    { "id": "e2", "kind": "fade", "start": 6, "end": 7.5, "lane": 0, "level": 0.3 }
  ] }
```

**Image fields:** `file` (a path inside the recording's folder; PNG, JPEG, HEIC, TIFF, GIF, WebP or
BMP; a PNG keeps its transparency); `x`, `y` (its centre, 0–1 of the frame, top-left origin); `size`
(its height as a share of the frame's; its width follows the picture's shape); `rotation` (degrees);
`opacity` (0–1); `radius` (rounded corners, as a share of its shorter side, 0–0.5); `shadow`;
`animIn` (`pop`, `fade`, `rise`, `slide`, `spin`, `blur`, `none`; default `fade`, while `image` writes `pop`);
`animOut` (`fade`, the default, `pop`, `sink`, `blur`, `none`); `layer`, the side of the video its row
is on (see [Depth](#depth-layers-and-layer)).

**Its own moves, `moves`:** an image moves the way the video does. Each move has an `id` and lands at
time `t` (inside the image's span), having travelled for `duration` seconds before it (default 0.8),
in `style` (`smooth`, the default, `linear`, `spring`, `pop`, `swipe`, `fade`, `spin`, `zoom`). `to`
is where it lands: `x`, `y` (default 0.5), and `scale`, which multiplies `size` (1 keeps it, the
default; 0.5 halves it). Before its first move the image is at
`x`, `y` and `size`.

**Its own effects, `effects`:** each has an `id`, `kind`, `start`, `end` (inside the image's span)
and `lane` (its row under the image, 0 up, default 0). They ease in and out over 0.3 s and touch only this
image. Kinds: `blur`; `mono` (black and white); `fade` (to `level`, an opacity of 0–1, default 0.3);
`pulse`, `float` and `wiggle` (a gentle motion while they last). Two effects on one `lane` must not
overlap, nor two of the same kind on any lane (`image-one-each`).

**Lanes:** images that follow one another share a lane. Images that show at the same time need
separate lanes; the rows' order in `layers` says which is in front, lane 0 the front one when it is left out.

To blur or grey more than one image, use a `blur` or `mono` segment with a `scope` (see
[Where an effect applies](#where-an-effect-applies)): `"frame"` covers the images, texts stay sharp; `"all"` the texts too.

### Masks

A mask hides a part of the recording: an API key, an email, a name. It is an effect on the video,
on the video's effect lanes, with `start` and `end` like a blur.

```json
{ "id": "mask1", "kind": "mask", "start": 2, "end": 8, "lane": 1,
  "rect": { "x": 0.1, "y": 0.2, "w": 0.3, "h": 0.05 }, "style": "blur" }
```

**Mask fields:** `rect` (what it hides: `x`, `y` its top-left corner, `w`, `h` its size, all 0–1 of
the **full recorded frame (before the crop)**, origin top-left; required); `style` (`blur`, the default; `pixels`; or `solid`); `color` (for
`solid`: `"#RRGGBB"`, or a text colour's name; default black); `radius` (rounded corners, as a share of
its shorter side, 0–0.5; default 0).

- **`rect` is in the full recorded frame (before the crop),** not in the frame you see and not in the
  crop. The finished frame adds a crop, a background, padding, a zoom and moves; the mask ignores all
  of them. So a later crop never moves it off the secret, and it stays on the same content when the
  video is placed, moved, zoomed or turned in 3D.
- Only the part inside the crop shows. A mask partly outside the crop hides what is visible of it; one
  fully outside hides nothing, and `show` says so.
- **It never fades.** It is at full strength on every frame from `start` to `end`. Let it start a
  little before the secret shows and end a little after.
- It is applied first, before the video's own blur and black and white, so they cannot weaken it.
  12 pt text is unreadable under any style.
- It hides a fixed place in the recording. When the secret moves (a page scrolls), add a mask for
  each place, one after another, or use a larger one.
- The drawn cursor is drawn over a mask.
- Masks may show at the same time, on separate lanes. They never clash with each other or with other effects.

**Finding where a secret is.** Render the full recorded frame at a moment it shows:

```sh
./exact-studio frame <id> 4.5 --raw --out secret.png
```

This is the recording itself, before the crop, at its own pixel size, with no edits: the picture
`rect` measures. It prints its size, for example `2514×1772`, and where the crop lies in it. Find the
secret in it. A pixel at (px, py) is `x = px / 2514`, `y = py / 1772`; its width and height divide the
same way. Leave a margin of a few pixels on each side. Do not measure on the normal `frame`: it is the
finished frame, with the crop, background, padding and moves.

```sh
./exact-studio mask <id> --rect 0.1,0.2,0.3,0.05 --at 4 --for 6 [--style pixels] [--color '#000000']
```

adds it on the first effect lane free then (else a new one) and prints it. Then render a normal frame
at its start, its middle and its last moment, and look: the secret must be covered on each.

### Sounds

A sound is music or an effect played over the video, from a file in the recording's folder.

```sh
./exact-studio sound <id> ~/Music/theme.m4a --at 0 --for 18
```

copies the file to `sounds/theme.m4a`, adds a sound at 0 s of the recording that plays 18 s of the
file (without `--for`: all of it, or what fits before the video ends), and prints it. Then edit it in
`sounds` like anything else.

**An added sound is not cut, sped up or slowed by the video's cuts and speed changes.** Only its
`start` is in recording time, like every time in the file, so it stays with that moment of the video
when you cut earlier parts. From there it plays straight through, in video time, for `length`
seconds or until the video ends. A `start` inside a removed part begins at the next kept moment.
Music that jumps at every cut sounds wrong; the recorded sound (`volume`) is the one that follows the
cuts. `show` prints when each sound plays in video time.

**Sound fields:** `id` (unique among the sounds, no colon); `file` (a path inside the recording's
folder, in `sounds/`: M4A, MP3, WAV, AIFF, AAC or CAF); `lane` (0 up); `start`
(seconds of the recording); `length` (seconds of the file that play, above 0); `offset` (where in
the file it starts, default 0; `offset` + `length` must fit in the file); `volume` (0–1, default 1);
`fadeIn`, `fadeOut` (seconds, default 0); `joinStart`, `joinEnd` (see [Splits and joins](#splits-and-joins-joinstart-joinend)). Two sounds on one lane must not play at the same time; put
one on lane 1. Sounds on separate lanes mix with each other and
with the recorded sound.

To trim a sound's beginning, add the same amount to `offset` and `start` (when no cut lies between)
and take it from `length`.

### What may overlap: the rules

The app, `validate` and MCP's `write_edits` check the same rules and say the same two lines. Line 1
names the rule; line 2 names the other item or time, and one way out. `validate` prints the item,
the other item, the rule's id, then both lines:

```text
zoom z2 (0:13.00–0:16.40), with zoom z1: one-zoom: One zoom at a time.
  Zoom in 2× runs to 0:17.6. Start it at 0:17.6 or later.
```

When `validate` names a rule, do what its second line says. Times in the lines are rounded the safe
way: "start at" later, "end by" earlier.

| id | rule | line 1 | line 2, for example |
|---|---|---|---|
| `one-zoom` | One zoom at a time, anywhere: zoom in and zoom out alike. | One zoom at a time. | Zoom in 2× runs to 0:17.6. Start it at 0:17.6 or later. |
| `one-speed` | One speed change at a time. | One speed at a time. | Slow 0.5× starts at 0:09.4. End it by 0:09.4. |
| `one-3d` | One `3d` at a time, hold or orbit. | One 3D turn at once. | 3D orbit runs to 0:05.0. Start it at 0:05.0 or later. |
| `one-spotlight` | One spotlight at a time. | One spotlight at a time. | Spotlight runs to 0:04.0. Start it at 0:04.0 or later. |
| `one-highlight` | One cursor highlight at a time. | One highlight at a time. | Cursor highlight runs to 0:04.0. Start it at 0:04.0 or later. |
| `one-blur` | One `blur` at a time, whatever its `scope` (video, background, scene, frame or all). | One blur at a time. | Blur · whole frame runs to 0:35.0. Start it at 0:35.0 or later. |
| `one-mono` | One `mono` at a time, whatever its `scope`. | One black & white at once. | Black & white runs to 0:12.0. Start it at 0:12.0 or later. |
| `no-zoom-in-orbit` | No `zoom` during a `3d` with `style` `"orbit"`: half way the screen faces away. | No zoom during an orbit. | 3D orbit runs to 0:05.0. Start it at 0:05.0 or later. |
| `move-after-move` | A move starts travelling (`t - duration`) only after the move before it lands: for `moves` and for each image's own. | One move at a time. | The move before lands at 0:09.0. Land this one at 0:09.8 or later. |
| `lane-taken` | Two items on one lane never overlap; sounds by when they play in the video. | That lane is taken. | Spotlight is on this lane then. Put it on another lane. |
| `image-one-each` | On one image, one of each effect kind at a time. | One of each per image. | Its pulse runs to 0:06.0. Start it at 0:06.0 or later. |
| `image-inside` | An image's own effects and moves stay inside its time. | Keep it inside the image. | logo.png shows 0:30.0–0:36.0. Start and end it there. |
| `image-effect-kind` | An image's own effect is one of its six kinds. | No such image effect. | An image takes blur, mono, fade, pulse, float or wiggle. |
| `text-one-each` | On one text, one of each effect kind at a time. | One of each per text. | Its blur runs to 0:04.0. Start it at 0:04.0 or later. |
| `text-inside` | A text's own effects stay inside its time. | Keep it inside the text. | “Hi” shows 0:01.0–0:06.0. Start and end it there. |
| `text-effect-kind` | A text's own effect is blur, mono or fade. | No such text effect. | A text takes blur, mono or fade. |
| `min-length` | Every item lasts 0.1 s or more. | Too short. | An item lasts at least 0.1 s, inside 0:00–0:42.0. |
| `keep-a-part` | At least one clip part is kept. | Keep one clip part. | The video needs at least one kept part. |
| `room-at-playhead` | The app only: an add needs 0.3 s free of its kind at the playhead. | (its kind's line 1) | A zoom runs here until 0:16.0. Move the playhead past it. |

Texts, images and masks on separate lanes overlap freely. Taste (a spotlight with a zoom, zooms back
to back, a key point under a blur) is advice in [effects.md](effects.md), never a rule.

**In the app.** A change that would break a rule is refused, and the reason shows where it was
tried: beside the pointer while dragging, as the second line of a menu item that is off, under a
typed time. A drop on a taken lane is not refused: the item goes to the first free lane of its
kind, or a new one.

**A file from before.** A file that already breaks a rule, such as one written before `one-blur`
covered both reaches (a video blur under a whole-frame blur), still opens and keeps every edit; it
plays and exports as it always did. `validate` reports it, and the app marks the items and shows the
reason when one is selected. Only a change that breaks a rule anew is refused: `write_edits` lists
the old breaks as notes and saves, and `validate --since <old edits.json>` does the same. `export`
renders such a file as the app does and prints each broken rule as a warning; it refuses only an
unreadable file, an unfilled `[line]` or a broken field. `validate` still exits 1 on a broken rule.

### Placement and moves: `base`, `moves`

`base` is where the video sits before any move: `x`, `y` its centre (0–1, top-left origin, default
0.5), `scale` (1 fills the frame inside the padding, the default). Each move has an `id` and lands at
time `t`, having travelled for `duration` seconds before it (default 0.8), in `style`: `smooth` (the
default), `linear`, `spring`, `zoom` (through full screen), `swipe`, `fade`, `spin`, `pop`
([how each looks](effects.md#move-styles)). `to` is
where it lands (`x`, `y`, `scale`, with the same defaults as `base`), and `angles` (`tilt`, `turn`,
`roll` in degrees, each default 0) the 3D angle it lands at, used while `three.on`; without `angles`
it keeps the angle it had. A move starts travelling only after the one before it lands (`move-after-move`).

### 3D: `three`

`on` draws the video as a 3D object (a phone's real body, buttons and all, for a device recording).
`tilt` leans the top away, `turn` swings the right side away, `roll` turns it flat, all in degrees
(about −40 to 40 reads well). `thickness` is a share of its width (0.01–0.15); `edge` is `metal`,
`aluminum`, `glass` or `matte`. With all angles 0 it looks exactly like the flat picture.

## look.json

```json
{ "background": "ocean", "aspect": "16:9", "padding": 8, "radius": 14, "shadow": true,
  "cursor": true, "cursorSize": 1.5, "clickEffect": true, "smoothCursor": true,
  "customA": "#9BAEBA", "customB": "#F0F4F5", "customAngle": 180, "customRadial": false }
```

`background` is a preset (`ocean`, `sunset`, `mint`, `midnight`, `graphite`, `paper`, `peach`, `lagoon`, `berry`,
`aurora`, `ember`, `lavender`, `citrus`, `forest`, `sky`, `rose`, `dusk`, `steel`, `candy`, `deepsea`, `sand`,
`neon`, `glow`, `noir`), `"custom"` (from `customA` to `customB`, at `customAngle` degrees as in CSS, or
radial), or `"video"` (the recording itself, blurred). `aspect` is `16:9`, `9:16`, `1:1`, `4:3` or
`auto` (the subject's own shape). `padding` is a percentage of the frame's shorter side; `radius`
the corners in output pixels (a device keeps its own shape). `cursorSize` is a scale (1.5 = 150%);
the cursor settings apply to recordings made without the system cursor in the picture.

## meta.json

Rarely edited. `crop` (unit rectangle, top-left origin) is what of the capture is shown; `clicks`
and `releases` drive Zoom on Clicks and the cursor's squeeze; `device`, `mask`, `maskRect` and
`cornerRadius` describe a device found in the picture. For a window recording, `cornerRadius` is
the window's own corner radius (a share of its width), measured from its alpha.

## Templates

`./exact-studio template <id> <name>` replaces the texts, effects, zooms and moves with a ready-made
edit, and keeps the cuts, speed changes, transitions, 3D settings, images, masks and sounds. Each
template fits the recording: its length as it plays (after cuts), its clicks, and the frame's shape
and background from `look.json`. `./exact-studio template --list` prints them.

| Name | Title | What it does | For |
|---|---|---|---|
| `clean` | Clean Demo | A zoom around the busiest clicks, no text; refused when no click leaves room for a zoom | A demo the screen explains |
| `hero` | Hero Angle | Opens at a slight 3D angle (tilt 8°, turn under 20°), then zooms on clicks | A page header or a loop |
| `before-after` | Before / After | "Before" then "After" beside the video, split at the cut nearest the middle, else at the click followed by the longest pause | A fix or a redesign |
| `spotlight` | Feature Spotlight | One zoom on the key click (the one followed by the longest pause), then one line to fill | One feature |
| `social` | Social Hook | A hook line to fill in the first seconds, then zooms on clicks | A feed |
| `steps` | Tutorial Steps | A numbered line to fill for each step, started by the clicks, at most five | A how-to |
| `launch` | Product Launch | A title and, from 14 s, a pitch over a blurred opening, zooms, then a closing line beside the video; 10 s at least | A launch |

The copy never makes a claim. A template either writes no text, or writes an obvious placeholder in
brackets (`[Hook line]`, `1. [What to do]`). A text with `[` … `]` in it is **unfilled**: `show`
marks it `UNFILLED`, `validate` reports it and exits 1, and `export` refuses until it is written or
deleted. The app selects the first one after a template, ready to type. The app's **Export** refuses
the same lines: it lists each one by time and words (`0:00.2 [Hook line]`) and offers **Show First**,
which selects the first and focuses its Words field. A broken rule the app tolerates does not stop
either export. Each line has time on screen
for a six-word line by the reading-speed rule (`1.0 s + 0.3 s` a word, plus its animations), and
texts are one placement, style and animation, white on a dark background and black on a light one (a title over the blurred opening on a pill).
Zooms (1.6×, at least 2.5 s, 1 s apart) and the 3D turn never share a moment with a text.
