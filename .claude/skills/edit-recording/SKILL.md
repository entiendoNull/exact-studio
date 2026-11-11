---
name: edit-recording
description: Edit an Exact Studio screen recording as files — cut it, add texts, zooms, effects, moves, 3D, change its look — then check it, look at frames and export, without the app's UI. Use when asked to edit, cut, title, polish or export an Exact Studio recording or video.
---

# Editing an Exact Studio recording

A recording is a folder under `~/Movies/Exact Studio/Recordings/<id>/`. Its edit is two JSON files:
`edits.json` (the timeline) and `look.json` (the frame). Read `docs/edits.md` first: it has every
field, its units and the overlap rules; `schema/*.schema.json` are the JSON Schemas.

The loop, from this repository's root:

1. `./exact-studio list`, then `./exact-studio show <id>`: what the recording is and holds now.
2. Edit `edits.json` / `look.json` directly. Times are **seconds of the recording**, not of the
   video as it plays (cuts and speed changes make them differ; `show` prints both lengths).
   `./exact-studio template <id> launch|hero|tour|teaser` is a quick start to adjust from.
3. `./exact-studio validate <id>` until it prints `ok`.
4. `./exact-studio frame <id> <seconds>` and look at `.exact/frame.png` at the moments that matter
   (a title's middle, a move's landing, a cut). `--source` takes recording time.
5. `./exact-studio export <id>` when it looks right.

Rules that keep an edit looking good:

- Keep texts clear of the video: beside it in a wide frame, above or below it in a tall one, and
  not over a stretch where a zoom pulls the video under the text.
- Prefer a few strong moments over many effects; leave the first second plain or blurred under a title.
- Speed changes read as lag on screen recordings; use cuts instead.
- An id must be unique within its list; any string works.

If the app is open, it shows each change within a second: tell the person to look there.
