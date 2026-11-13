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
├── edits.json      the timeline: cuts, transitions, effects, texts, images, sounds, zooms, speed, moves, 3D
└── look.json       the frame: background, shape, padding, corners, shadow, cursor
```

JSON Schemas: [`schema/edits.schema.json`](../schema/edits.schema.json), [`schema/look.schema.json`](../schema/look.schema.json).

## The loop

```sh
./exact-studio list                      # ids, newest first
./exact-studio show latest               # parts, segments, moves and look, in readable form
./exact-studio image latest logo.png --at 2 --for 6   # a picture on top of the video; prints the new segment
./exact-studio sound latest music.m4a --at 0          # music over the video; prints the new sound
# …edit edits.json / look.json…
./exact-studio validate latest           # exit 1 with one line per problem
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

## edits.json

```json
{
  "splits": [4.2, 7.0],
  "removed": [0, 7.0],
  "transitions": { "4200": "crossfade" },
  "lanes": 1,
  "textLanes": 1,
  "frameLanes": 0,
  "base": { "x": 0.5, "y": 0.5, "scale": 1 },
  "moves": [],
  "three": { "on": false, "tilt": 0, "turn": 0, "roll": 0, "thickness": 0.06, "edge": "metal" },
  "volume": 1,
  "soundLanes": 1,
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

Every key is optional; a missing one takes its default.

### Cutting: `splits`, `removed`, `transitions`

The clip is cut at each time in `splits` (sorted). That makes parts: 0 to the first split, split to
split, the last split to the end. A part is left out of the video when its **start** is in
`removed` (0 for the first part). Where removed parts lie between two kept parts, `transitions`
says how the video passes from one to the next, keyed by the earlier kept part's **end in
milliseconds**, as a string: `"crossfade"` (0.6 s) or `"fade"` (through the background). No key is a
plain cut.

To cut out 10–14 s: add `10` and `14` to `splits`, `10` to `removed`.

The recorded sound, if any, follows the picture: it is cut, sped up and faded at the same places.
`volume` (0–1, default 1) sets how loud it is; 0 mutes it. Sounds you add are different: see
[Sounds](#sounds).

### Segments

Each has an `id` (any unique string without a colon), `kind`, `start`, `end` (at least 0.1 s apart)
and `lane` (0 up). A segment's kind decides which rows its `lane` counts:

| what | kinds | its `lane` counts | how many there are |
|---|---|---|---|
| an effect on the video | `zoom`, `speed`, `spotlight`, `highlight`, `3d`, and `blur` or `mono` with no `scope` | the video's effect lanes | `lanes` (at least 1) |
| a text | `text` | the text lanes | `textLanes` |
| an image | `image` | nothing shared: each image is its own row, and `lane` is its place among the images, 0 in front | one for each image |
| an effect on the whole picture | `blur` or `mono` with `scope` `"frame"` or `"all"` | the whole-frame lanes | `frameLanes` |

An effect on the video never touches a text or an image, and an image's own effects (below) never
touch the video. Two segments on one lane must not overlap in time, and these never overlap
anywhere: two `zoom`s, two `speed`s, two `3d`s, or two of the same visual effect with the same reach.
Texts and images overlap freely. Images are drawn over the video with the lowest `lane` in front,
and texts over the images.

A file with no `textLanes` is an old one, where texts and whole-frame effects shared the effect
lanes: the app sorts them into lanes of their own kind when it reads it.

| kind | fields | |
|---|---|---|
| `zoom` | `level` | above 1 zooms in toward the cursor (1.5–3 is usual), below 1 zooms out (0.5–0.85); eases in and out over 0.7 s |
| `speed` | `rate` | 0.25–8; 0.5 is half speed |
| `spotlight` | | darkens all but a circle around the cursor |
| `highlight` | | a soft glow under the cursor |
| `blur` | `scope` | none: only the video. `"frame"`: the whole picture, background and images included; texts stay sharp on top. `"all"`: texts too |
| `mono` | `scope` | black and white, the same reaches |
| `3d` | `tilt`, `turn`, `roll`, `style` | turns the video in 3D over its span and back, even with 3D off; `style` `"hold"` or `"orbit"` (one full turn) |
| `text` | see below | |
| `image` | see below | |

**Text fields:** `text` (the words); `x`, `y` (its centre, 0–1 of the frame, top-left origin);
`size` (its height as a share of the frame's, 0.04–0.12 is usual); `color` (`white`, `black`, `yellow`,
`pink`, `blue`, `mint`); `weight` (`regular`, `bold`, `heavy`, `rounded`); `style` (`plain`, `pill`, `box`,
`outline`, `shadow`); `animIn` (`letters`, `letters-pop`, `drop`, `typewriter`, `pop`, `spin`, `slide`, `rise`,
`blur`, `fade`, `none`); `animOut` (`fade`, `fall`, `letters`, `pop`, `sink`, `blur`, `none`); `loop` while
shown (`none`, `wave`, `pulse`, `float`, `wiggle`); `rotation` (degrees).

Keep a text clear of the video: put it beside the video when the frame is wide, above or below it
when tall, and not where a zoom pulls the video under it.

### Images

An image is a picture on top of the video: a logo, a badge, a screenshot, a sticker. Its file lives
in the recording's folder, so the recording stays whole when it is copied.

```sh
./exact-studio image <id> ~/Desktop/logo.png --at 2 --for 6
```

copies the picture to `images/logo.png`, adds this segment at 2 s of the recording for 6 s, and
prints it. Then edit the segment like any other:

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
`animIn` (`pop`, `fade`, `rise`, `slide`, `spin`, `blur`, `none`); `animOut` (`fade`, `pop`, `sink`,
`blur`, `none`).

**Its own moves, `moves`:** an image moves the way the video does. Each move lands at time `t`
(inside the image's span), having travelled for `duration` seconds before it, in `style` (`smooth`,
`linear`, `spring`, `pop`, `swipe`, `fade`, `spin`, `zoom`). `to` is where it lands: `x`, `y`, and
`scale`, which multiplies `size` (1 keeps it, 0.5 halves it). Before its first move the image is at
`x`, `y` and `size`.

**Its own effects, `effects`:** each has an `id`, `kind`, `start`, `end` (inside the image's span)
and `lane` (its row under the image, 0 up). They ease in and out over 0.3 s and touch only this
image. Kinds: `blur`; `mono` (black and white); `fade` (to `level`, an opacity of 0–1, default 0.3);
`pulse`, `float` and `wiggle` (a gentle motion while they last). Two effects on one `lane` must not
overlap, nor two of the same kind on any lane.

To blur or grey the whole picture instead, images included, use a `blur` or `mono` segment with
`scope` `"frame"` (texts stay sharp) or `"all"` (texts too).

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
folder, in `sounds/`: M4A, MP3, WAV, AIFF, AAC or CAF); `lane` (0 up, below `soundLanes`); `start`
(seconds of the recording); `length` (seconds of the file that play, above 0); `offset` (where in
the file it starts, default 0; `offset` + `length` must fit in the file); `volume` (0–1, default 1);
`fadeIn`, `fadeOut` (seconds, default 0). Two sounds on one lane must not play at the same time; put
one on another lane (`soundLanes` counts them). Sounds on separate lanes mix with each other and
with the recorded sound.

To trim a sound's beginning, add the same amount to `offset` and `start` (when no cut lies between)
and take it from `length`.

### Placement and moves: `base`, `moves`

`base` is where the video sits before any move: `x`, `y` its centre (0–1, top-left origin), `scale`
(1 fills the frame inside the padding). Each move lands at time `t`, having travelled for
`duration` seconds before it, in `style`: `smooth`, `linear`, `spring`, `zoom` (through full screen),
`swipe`, `fade`, `spin`, `pop`. `to` is where it lands (`x`, `y`, `scale`), and `angles` (`tilt`, `turn`,
`roll` in degrees) the 3D angle it lands at, used while `three.on`; without `angles` it keeps the
angle it had.

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
edit (`launch`, `hero`, `tour`, `teaser`) laid out for `look.json`'s `aspect`, and keeps the cuts,
transitions, 3D settings, images and sounds. A good start to adjust from.
