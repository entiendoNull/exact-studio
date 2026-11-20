---
name: edit-recording
description: Record the screen with Exact Studio without a person (a Simulator, a window, a display or an area), and edit an Exact Studio screen recording as files — cut it, add texts, images (logos, badges, pictures), music and sounds, zooms, effects, moves, 3D, masks that hide secrets (API keys, emails, names), change its look — then check it, look at frames and export, without the app's UI. Use when asked to record a demo, a flow or a screen with Exact Studio, or to edit, cut, title, brand, polish, redact, blur out or export an Exact Studio recording or video.
---

# Recording and editing with Exact Studio

A recording is a folder under `~/Movies/Exact Studio/Recordings/<id>/`. Its edit is two JSON files:
`edits.json` (the timeline) and `look.json` (the frame). Read `docs/edits.md` first: it has every
field, its units and the overlap rules; `schema/*.schema.json` are the JSON Schemas. `docs/effects.md`
says what each effect, move style, text and image animation, style and transition looks like on
screen, its timing and its limits, with picture strips.

This skill is the mechanics. To make a recording into promotional material (a launch video, a demo,
an ad, a social clip), also follow the `direct-recording` skill: it decides what to cut, where to
zoom, what the texts say and how long they stay. When Exact Studio itself gets in the way (a bug, a
confusing verb or doc, a missing feature), follow the `send-feedback` skill: note it, and ask the
owner before anything is sent.

## Recording

An agent can make the recording too. The app records, so it must be built; `sources` and `record start`
open it when it is not running. With the MCP server, the tools are `list_sources`, `start_recording`,
`recording_status` and `stop_recording`.

1. `./exact-studio sources`: what can be recorded now. The first word of each line is the name to use.
2. `./exact-studio record start "simulator:iPhone 17 Pro" --max 120`. A unique part of a name works too.
   It starts at once, with no picker. Always give `--max`, so it stops even if you never get to step 4.
   Exact Studio's own windows fade out while it records, so they never cover the source, and come back
   when it stops.
3. Drive the app you record with your other tools: tap, type, scroll. `record status` says how long so far.
4. `./exact-studio record stop`: it prints the new recording's id and folder.
5. Go on with that id: `show`, `validate`, `frame`, then edit and export as below.

- Everything on the source is recorded, notifications and secrets included. Prefer a Simulator or one
  window over a display. If a secret still shows, hide it with a mask (below).
- A start is refused when a recording is already running. Never stop a recording you did not start;
  `record stop` leaves a person's recording running unless you pass `--any` because they asked.
- When nothing or more than one source matches, the candidates are listed. Pick one and start again.
- Exit 3 means a person must allow Screen Recording for Exact Studio. Tell them and wait.
- Exit 4 means the app did not answer. Run `record status` before you try again.
- `--sound on|off` overrides the app's System Sound setting for this recording.

## Editing

The loop, from this repository's root:

1. `./exact-studio list`, then `./exact-studio show <id>`: what the recording is and holds now.
2. Edit `edits.json` / `look.json` directly. Times are **seconds of the recording**, not of the
   video as it plays (cuts and speed changes make them differ; `show` prints both lengths).
   `./exact-studio template <id> <name>` is a quick start to adjust from (`template --list`; docs/edits.md
   says what each does). It prints its `[bracketed]` lines to fill; `validate` and `export` refuse them
   until you write them or delete the text.
   To put a picture on the video, run `./exact-studio image <id> <picture> --at <t> --for <seconds>`:
   it copies the file into the recording and prints the new `image` segment, on the first image
   lane free at that time. Then edit that segment's place, size, moves and effects in `edits.json`. Never point `file` outside the
   recording's folder.
3. `./exact-studio validate <id>` until it prints `ok`. When validate names a rule (`one-zoom`,
   `move-after-move`… the table is in docs/edits.md), do what its second line says: it names the
   other item or time and one way out, in the words the app shows a person. A rule the file broke
   before you changed it is not refused (`write_edits` lists it as a note); fix it when it is yours to fix.
   When it says `edits.json` or `look.json` can't
   be read (broken JSON, a wrong type), every other verb and the app refuse the recording and never
   write over that file. Fix the file itself; do not delete or replace it, since it is the only copy of the edit.
4. `./exact-studio frame <id> <seconds>` and look at `.exact/frame.png` at the moments that matter
   (a title's middle, a move's landing, a cut). `--source` takes recording time. `--raw` renders the
   full recorded frame there instead, before the crop, to measure a mask on (see below).
5. `./exact-studio export <id>` when it looks right.

Rules that keep an edit looking good:

- Before you use an effect, a move style, an animation, a text style or a transition you have not
  used this session, read its entry in `docs/effects.md` (MCP: `effects_guide` with its name). Then
  check it on your recording: `./exact-studio strip <id> <from> <to> --source` renders its frames
  side by side in `.exact/strip.png`.
- Keep texts clear of the video: beside it in a wide frame, above or below it in a tall one, and
  not over a stretch where a zoom pulls the video under the text.
- Prefer a few strong moments over many effects; leave the first second plain or blurred under a title.
- Speed changes read as lag on screen recordings; use cuts instead.
- To keep only parts from the middle, also put the start of the part after the last split in `removed`,
  or the tail stays in: docs/edits.md ("Cutting") has the example.
- One blur and one black and white at a time, whatever each covers; no zoom during a 3D orbit; a
  move starts travelling only after the one before it lands. `validate` refuses these.
- An effect on the video (zoom, blur, spotlight…) never touches a text or an image. To change one
  image, give it its own `moves` and `effects`; a text takes its own `effects` too (`blur`, `mono`, `fade`). To blur or grey more
  than the video, give a `blur` or `mono` segment a `scope`: the cut in the stack background, video, images, texts. `"background"`
  covers the background only, `"scene"` the background and the video, `"frame"` the images too (texts stay sharp), `"all"`
  everything. To blur one image or one text alone, use its own `effects`. `docs/edits.md` has the table of which lanes each kind uses.
- A text or an image can sit behind the video: `"layer": "behind"`. It is drawn on the background and
  shows only where the video is not, so it needs a move (`moves`, or a smaller `base`) that uncovers it;
  check `frame` before and after that move. The text and image rows are one stack, front to back in
  `layers` (`"text:0"`, `"image:0"`, `"video"`): move a row there to change what is in front. A `background`
  reach stays under it; `scene` and above cover it. `docs/edits.md` ("Depth").
- For music or a sound effect, run `./exact-studio sound <id> <audio file> --at <t> [--for <seconds>]`:
  it copies the file into `sounds/` and prints the new entry in `sounds`. An added sound is not cut
  by the video's cuts or speed changes: it starts at recording time `start` and plays straight
  through. So add music after the cuts are set and check `show` for when it plays. Keep music
  under the recorded sound (`volume` 0.3–0.5) and give it a `fadeOut`; `volume` 0 mutes the recording.
- When a file is the app's own sound, lined up with the video (recorded outside Exact Studio), never
  add it as a sound and never cut it into one sound per kept part: run
  `./exact-studio sound <id> <file> --as-recorded [--offset <s>]`. It becomes the recorded sound
  (`recordedSound` in edits.json) in place of `capture.mov`'s, so it follows every cut, speed change
  and fade. Recording time t plays file time t + offset; outside the file it is silent. Never change
  `capture.mov`. `./exact-studio sound <id> --as-recorded off` goes back to its own sound; `show` says which plays.
- Do not add a lane unless two items of its kind overlap in time. Leave the lane counts out. Images shown
  one after another share an image lane; images at the same time go on lanes 0 and 1. When validate names
  a rule, do what its second line says.
- Keep an image small and near a corner unless it is the subject: a logo at `size` 0.08–0.15, a
  picture that carries a moment at 0.3–0.5. Look at a frame after placing it.
- An id must be unique within its list and hold no colon; any other string works.
- To change a block partway (a text's words, a zoom's level, a sound's volume), split it first:
  `./exact-studio split <id> <t> <item>` (an image's effect: `<image>:<effect>`), or `--all` to cut
  the clip and every block at `<t>`. The halves are joined (`joinEnd`, `joinStart`), so the video
  stays the same until you change one; then nothing eases or animates where they meet. To make a
  half ease or animate on its own, move it apart, or remove both join keys. `validate` reports a
  join without its partner. Never hand-cut a block into two touching ones without the join keys:
  each would ease out and in at the cut.

## Hiding a secret with a mask

When the recording shows something private (an API key, a token, an email, a name, an address),
hide it with a mask. A mask is a segment of kind `mask` on the video's effect lanes. Its `rect` is in
the **full recorded frame (before the crop)**, not in the finished frame and not in the crop: x, y, w, h
in 0–1, origin top-left. So a later crop never moves it off the secret.

1. Find when it shows: `show <id>`, then `frame <id> <t> --source --raw` at a few times. `--raw`
   renders the full recorded frame at that moment, before the crop, with no edits, at its own pixel
   size. It prints that size, for example `2514×1772`, and where the crop lies in it. Never measure on
   a normal `frame`: that is the finished frame, with crop, background, padding, zoom and moves.
2. Find where it shows in that raw picture. Read its pixel box (left, top, width, height) and divide
   by the size: `x = left / 2514`, `y = top / 1772`, `w = width / 2514`, `h = height / 1772`. Add a
   margin of a few pixels on each side, and keep x + w and y + h at most 1. Only the part inside the
   crop shows; `show` says when a mask lies partly or fully outside it.
3. `./exact-studio mask <id> --rect x,y,w,h --at <start> --for <seconds> [--style blur|pixels|solid] [--color '#000000']`.
   Times are recording seconds. Start a little before the secret first shows and end a little after
   it goes: a mask never fades, and it hides nothing outside its span.
4. Check: `frame <id> <t> --source` at its start, its middle and its last moment, and at any zoom,
   move or 3D turn over it. Look at each PNG: the secret must be covered on every one.

- A mask hides a fixed place in the recording; it follows the video through zooms, moves and 3D on
  its own. When the secret moves inside the recording (a page scrolls, a window moves), add one mask
  per place, one after another, or one larger mask.
- `blur` (the default) looks softest; `pixels` reads as "censored"; `solid` is a plain box in `color`.
  All three hide 12 pt text.
- Masks that show at the same time go on separate lanes; `mask` picks a free one.
- The drawn cursor shows over a mask. To keep it off, set `cursor` to false in `look.json`; that hides it for the whole video.
- `validate` rejects a missing rect, a rect outside 0–1, a zero size, an unknown style and a bad colour.

If the app is open, it shows each change within a second: tell the person to look there.
