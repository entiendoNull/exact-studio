---
name: edit-recording
description: Record the screen with Exact Studio without a person (a Simulator, a window, a display or an area), and edit an Exact Studio screen recording as files — cut it, add texts, images (logos, badges, pictures), music and sounds, zooms, effects, moves, 3D, masks that hide secrets (API keys, emails, names), change its look — then check it, look at frames and export, without the app's UI. Use when asked to record a demo, a flow or a screen with Exact Studio, or to edit, cut, title, brand, polish, redact, blur out or export an Exact Studio recording or video.
---

# Recording and editing with Exact Studio

A recording is a folder under `~/Movies/Exact Studio/Recordings/<id>/`. Its edit is two JSON files:
`edits.json` (the timeline) and `look.json` (the frame). Read `docs/edits.md` first: it has every
field, its units and the overlap rules; `schema/*.schema.json` are the JSON Schemas.

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
   `./exact-studio template <id> launch|hero|tour|teaser` is a quick start to adjust from.
   To put a picture on the video, run `./exact-studio image <id> <picture> --at <t> --for <seconds>`:
   it copies the file into the recording and prints the new `image` segment, on the first image
   lane free at that time. Then edit that segment's place, size, moves and effects in `edits.json`. Never point `file` outside the
   recording's folder.
3. `./exact-studio validate <id>` until it prints `ok`. When it says `edits.json` or `look.json` can't
   be read (broken JSON, a wrong type), every other verb and the app refuse the recording and never
   write over that file. Fix the file itself; do not delete or replace it, since it is the only copy of the edit.
4. `./exact-studio frame <id> <seconds>` and look at `.exact/frame.png` at the moments that matter
   (a title's middle, a move's landing, a cut). `--source` takes recording time. `--raw` renders the
   full recorded frame there instead, before the crop, to measure a mask on (see below).
5. `./exact-studio export <id>` when it looks right.

Rules that keep an edit looking good:

- Keep texts clear of the video: beside it in a wide frame, above or below it in a tall one, and
  not over a stretch where a zoom pulls the video under the text.
- Prefer a few strong moments over many effects; leave the first second plain or blurred under a title.
- Speed changes read as lag on screen recordings; use cuts instead.
- An effect on the video (zoom, blur, spotlight…) never touches a text or an image. To change one
  image, give it its own `moves` and `effects`. To blur or grey the whole picture at once, images included, use a `blur` or
  `mono` segment with `scope` `"frame"` (texts stay sharp) or `"all"` (texts too). `docs/edits.md` has the table of which lanes each kind uses.
- For music or a sound effect, run `./exact-studio sound <id> <audio file> --at <t> [--for <seconds>]`:
  it copies the file into `sounds/` and prints the new entry in `sounds`. An added sound is not cut
  by the video's cuts or speed changes: it starts at recording time `start` and plays straight
  through. So add music after the cuts are set and check `show` for when it plays. Keep music
  under the recorded sound (`volume` 0.3–0.5) and give it a `fadeOut`; `volume` 0 mutes the recording.
- Images shown one after another share an image lane. Put images that show at the same time on
  separate lanes: the lower `lane` is in front. Raise `imageLanes` when you add a lane.
- Keep an image small and near a corner unless it is the subject: a logo at `size` 0.08–0.15, a
  picture that carries a moment at 0.3–0.5. Look at a frame after placing it.
- An id must be unique within its list and hold no colon; any other string works.

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
