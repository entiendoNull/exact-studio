---
name: edit-recording
description: Edit an Exact Studio screen recording as files — cut it, add texts, images (logos, badges, pictures), music and sounds, zooms, effects, moves, 3D, change its look — then check it, look at frames and export, without the app's UI. Use when asked to edit, cut, title, brand, polish or export an Exact Studio recording or video.
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
   To put a picture on the video, run `./exact-studio image <id> <picture> --at <t> --for <seconds>`:
   it copies the file into the recording and prints the new `image` segment. Then edit that
   segment's place, size, moves and effects in `edits.json`. Never point `file` outside the
   recording's folder.
3. `./exact-studio validate <id>` until it prints `ok`.
4. `./exact-studio frame <id> <seconds>` and look at `.exact/frame.png` at the moments that matter
   (a title's middle, a move's landing, a cut). `--source` takes recording time.
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
- Keep an image small and near a corner unless it is the subject: a logo at `size` 0.08–0.15, a
  picture that carries a moment at 0.3–0.5. Look at a frame after placing it.
- An id must be unique within its list and hold no colon; any other string works.

If the app is open, it shows each change within a second: tell the person to look there.
