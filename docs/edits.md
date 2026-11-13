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
├── edits.json      the timeline: cuts, transitions, effects, texts, zooms, speed, moves, 3D
└── look.json       the frame: background, shape, padding, corners, shadow, cursor
```

JSON Schemas: [`schema/edits.schema.json`](../schema/edits.schema.json), [`schema/look.schema.json`](../schema/look.schema.json).

## The loop

```sh
./exact-studio list                      # ids, newest first
./exact-studio show latest               # parts, segments, moves and look, in readable form
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
  "lanes": 2,
  "base": { "x": 0.5, "y": 0.5, "scale": 1 },
  "moves": [],
  "three": { "on": false, "tilt": 0, "turn": 0, "roll": 0, "thickness": 0.06, "edge": "metal" },
  "volume": 1,
  "segments": [
    { "id": "t1", "kind": "text", "start": 4.3, "end": 7.0, "lane": 0, "text": "Hello", "x": 0.5, "y": 0.15,
      "size": 0.08, "color": "white", "weight": "heavy", "style": "pill", "animIn": "letters", "animOut": "fade" },
    { "id": "z1", "kind": "zoom", "start": 8.0, "end": 11.0, "lane": 1, "level": 1.6 }
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
`volume` (0–1, default 1) sets how loud it is; 0 mutes it.

### Segments

Each has an `id` (any unique string), `kind`, `start`, `end` (at least 0.1 s apart) and `lane` (0 up;
`lanes` is how many lanes the timeline shows). Two segments on one lane must not overlap in time,
and these never overlap anywhere: two `zoom`s, two `speed`s, two `3d`s, or two of the same visual
effect. Texts overlap freely on separate lanes.

| kind | fields | |
|---|---|---|
| `zoom` | `level` | above 1 zooms in toward the cursor (1.5–3 is usual), below 1 zooms out (0.5–0.85); eases in and out over 0.7 s |
| `speed` | `rate` | 0.25–8; 0.5 is half speed |
| `spotlight` | | darkens all but a circle around the cursor |
| `highlight` | | a soft glow under the cursor |
| `blur` | `scope` | `"video"` (default) or `"frame"`: the whole picture, background included; texts stay sharp |
| `mono` | `scope` | black and white, the same scopes |
| `3d` | `tilt`, `turn`, `roll`, `style` | turns the video in 3D over its span and back, even with 3D off; `style` `"hold"` or `"orbit"` (one full turn) |
| `text` | see below | |

**Text fields:** `text` (the words); `x`, `y` (its centre, 0–1 of the frame, top-left origin);
`size` (its height as a share of the frame's, 0.04–0.12 is usual); `color` (`white`, `black`, `yellow`,
`pink`, `blue`, `mint`); `weight` (`regular`, `bold`, `heavy`, `rounded`); `style` (`plain`, `pill`, `box`,
`outline`, `shadow`); `animIn` (`letters`, `letters-pop`, `drop`, `typewriter`, `pop`, `spin`, `slide`, `rise`,
`blur`, `fade`, `none`); `animOut` (`fade`, `fall`, `letters`, `pop`, `sink`, `blur`, `none`); `loop` while
shown (`none`, `wave`, `pulse`, `float`, `wiggle`); `rotation` (degrees).

Keep a text clear of the video: put it beside the video when the frame is wide, above or below it
when tall, and not where a zoom pulls the video under it.

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
transitions and 3D settings. A good start to adjust from.
