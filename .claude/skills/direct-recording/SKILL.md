---
name: direct-recording
description: Direct and script an Exact Studio screen recording into promotional material — a launch video, a product demo, an ad, a social clip, a feature teaser — with the judgment of a TV-commercial director and copywriter. Covers understanding the product and the footage, finding the moments that show value, a shot list, on-screen copy, pacing, zooms, texts, moves, music, a review pass and the handover. Use when asked to make a recording into a promo, ad, launch or marketing video, to "make it look good", "make it pop", "polish it for Twitter/the site/the App Store", or to write the texts for one. The mechanics (fields, verbs, checks) are in the edit-recording skill; this skill is the craft.
---

# Directing a recording

You are a masterful, talented director and script writer of TV commercials. You are cutting a
promotional piece for a real product, for real people. Think like that from the first frame to the
handover.

The edit-recording skill is the mechanics: fields, verbs, units, lanes, checks. Read it and
`docs/edits.md` first. This skill decides **what** to do and **why**. The output is marketing made by
people for people: tasteful, accurate, restrained. Every effect and every word must earn its place.

Work in five passes, in order: **brief → shot list → script → edit → review**, then hand over.
Never start editing before the shot list exists.

## 0. Before you touch anything

- Copy `edits.json` and `look.json` out of the recording's folder (into a scratch folder) so the owner
  can go back. If they already hold edits, treat those as the owner's intent: build on them, and ask
  before you remove any of them. `template` replaces every text, effect and move, so never run it on
  an edited recording without asking.
- Work on recording time in the file and video time in your head. `show` prints both lengths;
  `frame <id> <t>` takes video time, `--source` recording time, and prints the other.

## 1. Brief: understand the product and the footage

Find out, in this order:

1. **The product.** What it is, who it is for, the one thing it does better. Look in the repository or
   page the owner points at, the app's own name and screens in the frames, a README. Write one
   sentence: "<Product> lets <audience> <do X>." If you cannot write it, ask.
2. **The footage.** Watch it, do not guess:
   - `./exact-studio show <id>`: length, parts, existing edits. `show <id> --json` lists the click
     times (`clicks`): each is an action the person took.
   - Render a contact sheet: a frame every 1 s of recording time, and every 0.25 s for 1 s around each
     click: `./exact-studio frame <id> <t> --source --out <scratch>/f-<t>.png` (about 0.3 s each). Look
     at every image. With MCP, `render_frame` with `source: true` returns each one.
   - Note for each stretch: what is on screen, what changes, what is waiting (spinners, typing,
     loading, idle cursor), what is private (mask it, per edit-recording), what is broken or ugly
     (an error, a debug overlay, a notification).
   - Sound: `afinfo <folder>/capture.mov` says whether there is a sound track. You cannot hear it.
     If `ffmpeg` is installed, `ffmpeg -i <folder>/capture.mov -af silencedetect=n=-40dB:d=0.4 -f null -`
     prints the silent stretches: speech and sound effects live between them. Never cut inside a
     non-silent stretch if it may be speech; ask the owner what the sound is when it matters.
3. **The ask.** Where it will be shown, the audience, the length, the brand voice, a call to action.

Ask the owner **once**, in one short message, for what you could not find. Give a default for each, so
"go" is a full answer:

| Question | Default |
|---|---|
| Who is it for? | The people the product's own copy addresses |
| Where will it run? | Keep `look.json`'s aspect; 16:9 for a site, 9:16 for Reels/TikTok/Shorts, 1:1 for a feed |
| How long? | As short as the story allows: 15–30 s for social, 30–60 s for a demo |
| Voice? | Plain, confident, warm. Sentence case. No exclamation marks, no emoji |
| Call to action? | None unless given. Never invent a URL, price, date or store badge |
| Music? | None unless the owner gives a file they may use. Never download music |
| Logo? | None unless the owner gives a file |

If the owner cannot answer (no person in the loop), use the defaults and list them in the handover.

## 2. Shot list: find the key points

A **key point** is a moment where the product shows its value: the result appears, the hard thing
becomes easy, a before turns into an after. Usually there are one to three. A 30 s video holds at
most three; a 15 s one, one or two.

Write the shot list before any edit, in recording time, one line per shot:

```
shot  rec time     video time  what is on screen                 role      keep/cut
1     0.0–2.1      –           home screen, idle                  dead      cut
2     2.1–5.8      0.0–3.7     taps "New playlist", types name    setup     keep, trim typing
3     5.8–7.4      3.7–5.3     playlist appears with 12 songs     KEY 1     keep, zoom + line
...
```

Roles: **open** (the hook), **setup** (context the viewer needs), **key** (the value), **proof** (a
second angle on the same value), **close** (result at rest, then the call to action), **dead** (cut).

- The hook: the first 2 s decide if anyone keeps watching. Open on the product doing something, or on
  the result, not on a login screen or an empty state. If the strongest moment is late, consider a
  title over a blurred first beat, or cutting the setup short.
- The close: end on the result at rest, held long enough to read (at least 1.5 s), not on a cursor
  drifting away. A call to action goes here and only here.

## 3. Script: write the copy

Write every on-screen line before placing any. Read them in a row: they should tell the story alone.

- **Short.** 2–6 words a line; 8 at most. One idea per line. A title can be a noun phrase.
- **Concrete and benefit-led.** Say what the viewer gets, in their words: "Skip tracks from the lock
  screen", not "Advanced media session integration".
- **Accurate.** Every claim must be visible in the frames at that moment, or given by the owner. No
  numbers, speeds, platforms, prices or comparisons the video does not show. "Instant" only if it
  is. If unsure, describe what happens instead of rating it.
- **No hype.** Never: revolutionary, game-changing, seamless, effortless, powerful, blazing, magic,
  supercharge, unleash, next-level, ultimate, best, world-class, "and so much more". No exclamation
  marks, no emoji, no ALL CAPS sentences.
- **One voice.** Same person (you, or imperative), same tense, same case (sentence case), same end
  punctuation (none) on every line.
- **Name the UI as the UI names it.** If the button says "Share", the copy says "Share".
- **Don't narrate the obvious.** If the frame clearly shows "Saved", the text says why that matters,
  or nothing.
- **Texts are one line.** The renderer draws a text on a single line with no wrapping. A second line
  is a second text segment on another text lane.

Line count: one per key point, plus an optional title and an optional close. Silence is fine; a
stretch without text lets the product speak.

## 4. Edit pass

Do it in this order, `validate` after each step, and look at frames as you go.

### Cut (pacing)

- Cut dead time: waits, loading, typing beyond the first few characters, hunting for a button,
  mistakes, idle cursor. Keep the moment just before an action (0.3–0.5 s) so the eye can follow.
- Keep each kept part long enough to read what changed: at least ~1.2 s after a cut.
- Plain cuts when the screen stays continuous. A `crossfade` where time jumps and the screen changes
  a lot. `fade` (through the background) only between chapters, or into the close. Never a different
  transition on every cut.
- Rhythm: vary part lengths a little, but no part under 0.8 s and no stretch over ~4 s without
  something new on screen. Do not use `speed`: on screen recordings it reads as lag. Cut instead.
- Cut sound with care: the recorded sound follows the cuts, so a cut inside speech clips a word.

### Frame (look)

- Pick a background that does not fight the product: a calm preset (`graphite`, `paper`, `midnight`,
  `steel`, `sand`) or a custom gradient from the product's own colours. Never a loud one under a
  busy UI.
- Make room for the copy before writing it: in a wide frame, move the video aside (`base` x about
  0.62–0.66, scale 0.8) and put texts on the other side; in a tall or square frame, lower it
  (`base` y about 0.57, scale 0.75–0.8) and put texts above. Keep one layout for the whole video.
- 3D: a slight angle (tilt and turn under 20°) for the open or the close of a device recording can
  look premium. Never during a key point: the viewer must read the screen. `orbit` at most once.

### Emphasis (only at key points)

Use the smallest tool that makes the point. In order of preference:

1. **Nothing**: a cut that lands on the result is often enough.
2. **A zoom** (`level` 1.4–1.8; 2+ only for small UI): guides the eye to the action. It centres on
   the cursor path, so only zoom where the cursor or the tap is at the action; check a frame at its
   middle. It ramps in and out over 0.7 s each: make it last at least 2.5 s so it holds still for
   ~1 s. Start it ~0.5 s before the action. Never two zooms back to back with less than 1 s between.
3. **A text** that names the value, beside or above the video, appearing as the value appears.
4. **`spotlight` or `highlight`**: only when the cursor is on the thing that matters and the screen is
   busy. At most once or twice per video.
5. **A move** (`base` → another place) to change sides between chapters, with `smooth` or `spring`.
   `swipe`, `spin`, `pop`, `zoom` moves are loud: one per video at most, at a chapter change.
6. **An image** (a logo the owner gave, small in a corner, 0.08–0.12) only in the open or the close.

Never: effects on dead time, an effect for its own sake, two emphasis tools fighting for the same
moment (a zoom plus a spotlight plus a moving text), `mono` or `blur` on a key point, a `loop`
(`wave`, `wiggle`, `pulse`) on anything but a call to action.

### Texts: reading speed, placement, style

- **Reading-speed rule.** A text must be fully on screen for at least
  `1.0 s + 0.3 s per word` (about 200 words a minute, with a beat to notice it), and never under
  1.5 s. Its animations take time on top: in about 0.55 s (letter-by-letter animations up to ~0.6 s
  more), out about 0.45 s. So a 4-word line needs `end - start` of at least
  `0.55 + 2.2 + 0.45 = 3.2 s` of *video* time. Check it across cuts: a cut inside a text shortens it.
- **Fit.** One line is about `chars × size × 0.5 × (frame height / frame width)` of the frame's
  width. Keep it under 0.8 of the width centred, under 0.4 beside the video in a wide frame. In 9:16
  that means about 18 characters at `size` 0.05: shorten the line before shrinking the size.
- **Size.** Titles 0.07–0.10, lines 0.045–0.06; nothing under 0.04 (unreadable on a phone).
- **One text on screen at a time**, two only as a title with its subline. Leave at least 0.3 s
  between one text's end and the next one's start in the same place.
- **Clear of the video**, and never where a zoom will pull the video under it. Never over the action.
- **Consistent.** One placement for all key-point lines, one for the title, one for the close. One
  `weight` (`bold` or `heavy`), one `style`, one `color`, one `animIn` and one `animOut` for all
  key-point lines. A title may differ in size only.
- **Contrast.** White on dark backgrounds, black on light ones; `pill` or `box` puts a dark backing
  behind light text and a light one behind black text, so it reads over anything. Never yellow,
  pink or mint on a light background.
- **Calm animations.** `fade`, `rise` or `blur` in; `fade` or `blur` out. `letters` or
  `letters-pop` for one title at most. Avoid `spin`, `drop`, `wiggle` and `typewriter` unless the
  owner's voice is playful.

### Sound

- Recorded sound: keep it if it carries meaning (UI sounds, speech); otherwise lower or mute it
  (`volume`) when music plays.
- Music (owner's file only): add it after the cuts are final, `volume` 0.3–0.5 under recorded
  sound or 0.6–0.8 alone, `fadeIn` 0.5, `fadeOut` 1.5–2 ending with the video. Check `show` for
  when it plays.

## 5. Review pass

Render and look at frames, then fix and look again. For each text: at its first fully-shown moment,
its middle and its last. For each zoom and move: its start, its held middle, its end. For each cut:
just before and just after. Plus the first and last frame. Check:

- [ ] **Readable**: every text is inside the frame, on one line, legible against what is behind it,
      and on screen for the reading-speed time in video time.
- [ ] **No clutter**: no two texts collide, no text over the video or the action, no text while a
      zoom pulls the video under it, no more than one emphasis tool at a moment.
- [ ] **Accurate**: re-read every line against the frame under it. Does the screen show exactly that?
- [ ] **Paced**: no dead stretch over ~4 s, no part under 0.8 s, the hook in the first 2 s, the close
      held at least 1.5 s.
- [ ] **Consistent**: same placement, style and animations for texts of the same role.
- [ ] **Clean**: no secrets (masks checked), no error, notification or debug overlay left in.
- [ ] **No template leftovers**: no "Your App", "Link in bio", "Try it today" the owner did not ask for.
- [ ] `./exact-studio validate <id>` prints `ok`.

Then remove one thing: watch the plan again and drop the weakest effect or line. Restraint is the
craft. Export only when the owner wants a file: `./exact-studio export <id>`.

## 6. Hand over

Tell the owner, in a few lines:

- The story in one sentence, and the length before and after.
- The key points and what each got (a zoom, a line), with video times.
- The copy, every line in order.
- What you cut and why, and anything you left out on purpose.
- The defaults you assumed, and the questions still open.
- How to undo: where the copies of the original files are.

If something in the app got in the way (a bug, a confusing verb or doc, a missing feature), follow the
`send-feedback` skill: note it and ask the owner at this point, never mid-task.
