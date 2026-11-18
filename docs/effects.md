# What each effect looks like

How every placeable thing in [`edits.json`](edits.md) behaves on screen: what the viewer sees, its
timing, its parameters, what it touches and when to use it. [edits.md](edits.md) has the fields and
the overlap rules; this file has the behaviour. Read an entry before you use a thing for the first time.

- Times are seconds of the recording, as everywhere in `edits.json`. Ramps and animations run in
  recording time too, so inside a `speed` change they play faster or slower with the video.
- "The frame" is the finished picture (the canvas). "The video" is the recording placed on it.
- "Eases" means a smooth start and stop (no jolt). A **ramp** is the ease at each end of a span; it
  is never longer than half the span.
- **Joined halves** (a split, see [edits.md](edits.md#splits-and-joins-joinstart-joinend)) ramp only
  at the run's outer ends. A setting changed on the second half (a zoom's level, a 3D angle) jumps at the cut.
- Each strip is a few frames side by side, left to right, rendered by `test/make-effect-strips.sh`
  with the app's renderer on a made-up window recording. Its caption gives the recording times.
- Render your own: `./exact-studio strip <id> <from> <to> [--frames 5] [--source]` puts frames of
  your recording side by side in `.exact/strip.png`; `frame` renders one.

Templates (`launch`, `hero`, `tour`, `teaser`) are ready-made sets of the things below; see
[edits.md](edits.md#templates).

## Effects on the video

These touch only the video: never the background, a text or an image. Each lives on the video's
effect lanes. The drawn cursor is drawn over them, so it stays sharp under a blur or a spotlight.

### `zoom`

![zoom 2× from 1 to 5 s](effects/zoom-in.png)
![zoom 0.7× from 1 to 5 s](effects/zoom-out.png)

*Top: `level` 2, 1–5 s, frames 0.9–5.1 s. Bottom: `level` 0.7.*

- **Sees:** above 1, the video grows toward the cursor, as a camera push-in; the view follows the
  cursor while it holds. Below 1, the video shrinks toward the frame's centre, showing more background.
- **Timing:** eases in over 0.7 s, holds, eases out over 0.7 s. The view follows the cursor
  averaged over about 0.35 s, so it glides.
- **Parameters:** `level` (default 2). In: 1.5–3 (the app offers 1.5, 2, 2.5, 3). Out: 0.5–0.85.
  Near 1 it does little.
- **Limits:** one zoom at a time anywhere. A zoom in never shows past the frame's edge, so near an
  edge the cursor is not centred. It scales the video with its shadow, masks and 3D slab; the
  background, texts and images stay put. It follows the video's moves. Without a cursor path it
  centres the video. Above 3 the picture goes soft.
- **Use:** to guide the eye to a small action at a key point. **Avoid:** zooms back to back, zooms
  where the cursor is not at the action, and zooms under a text.

### `speed`

- **Sees:** the video plays faster or slower over its span. The recorded sound speeds up or slows with it.
- **Timing:** no ramp: the rate changes at once at `start` and back at `end`. Everything timed in
  recording seconds inside the span (a zoom's ramp, a text's animation, a move) plays at the same rate.
- **Parameters:** `rate`, above 0. The app offers 0.25, 0.5, 0.75 (slow) and 1.5, 2, 4, 8 (fast).
- **Limits:** one speed change at a time anywhere. Added sounds keep their own pace. `show` prints the new length.
- **Use:** rarely; a fast 4–8× over a long wait can read as a time-lapse. **Avoid:** on screen
  recordings in general: it reads as lag. Cut instead.

### `spotlight`

![spotlight from 1 s](effects/spotlight.png)

*1–5 s, frames 0.9–2.5 s.*

- **Sees:** the video darkens, except a soft circle of light that follows the cursor.
- **Timing:** eases in and out over 0.25 s. The circle follows the cursor averaged over 0.2 s.
- **Parameters:** none. The clear centre is about 9% of the frame's short side across in radius,
  falling off to 62% dark at about 16%, measured before the video's scale.
- **Limits:** only the video darkens: the background, texts and images do not. It needs the cursor
  path; without one it draws nothing. One spotlight at a time anywhere.
- **Use:** once or twice, when the cursor sits on the thing that matters on a busy screen. **Avoid:**
  with a zoom or a moving text at the same moment; when the cursor wanders.

### `highlight`

![highlight from 1 s](effects/highlight.png)

*1–5 s, frames 0.9–2.5 s.*

- **Sees:** a small soft yellow glow right under the cursor's tip.
- **Timing:** eases in and out over 0.25 s. It follows the cursor exactly, not averaged.
- **Parameters:** none. About 3% of the frame's short side across in radius, yellow at 45%.
- **Limits:** as `spotlight`. It is small: at a zoom out or a small base scale it is hard to see.
- **Use:** to show where the clicks are in a tutorial. **Avoid:** in a promo, where it reads as a tutorial.

### `blur`

![blur, video only](effects/blur-video.png)

*No `scope`, 1–5 s, frames 0.8–1.6 s. The text and the image stay sharp.*

- **Sees:** the video goes soft; the background, texts and images stay sharp.
- **Timing:** eases in and out over 0.25 s.
- **Parameters:** `scope` (see [Whole-frame reach](#whole-frame-reach)). The strength is fixed.
- **Limits:** one blur with the same reach at a time. A mask is applied first, so a blur never weakens it.
- **Use:** under a title in the first second, or to rest the eye between chapters. **Avoid:** on a key point.

### `mono`

![black and white, video only](effects/mono-video.png)

*No `scope`, 1–5 s, frames 0.8–1.6 s.*

- **Sees:** the video fades to black and white; the background, texts and images keep their colour.
- **Timing:** eases in and out over 0.25 s.
- **Parameters:** `scope`, as `blur`.
- **Limits:** one with the same reach at a time.
- **Use:** for a "before" beat next to a colourful "after". **Avoid:** on a key point.

### `3d`

A 3D turn: the video turns to an angle and back over its span, as a slab with a body and an edge.
It works with 3D off (the video is a slab only during the span) and with 3D on (it turns from the
3D angle). Its `style` picks what it does:

#### `hold`

![3D hold, tilt 12 turn -28](effects/3d-hold.png)

*`tilt` 12, `turn` −28, 1–5 s, frames 1–5 s.*

- **Sees:** the video leans back to one angle, holds there, and comes back face on.
- **Timing:** eases to the angle over 0.7 s (a third of the span when it is under 2.1 s), holds, eases back.
- **Parameters:** `tilt` leans the top away, `turn` swings the right side away, `roll` turns it
  clockwise, in degrees. Missing: `tilt` 10, `turn` −24, `roll` 0. Under about 20° each reads as
  premium; past 60° the screen is hard to read.
- **Limits:** one 3D turn at a time. The shadow drops further and softer as it turns. Masks, the
  cursor and the video's effects turn with it; texts and images stay flat on top.
- **Use:** a slight angle on the open or the close of a device recording. **Avoid:** during a key point.

#### `orbit`

![3D orbit](effects/3d-orbit.png)

*`tilt` 8, 1–5 s, nine frames 1–5 s.*

- **Sees:** the video makes one full turn about its vertical axis, showing its edge and its dark
  back half way, and lands face on.
- **Timing:** the turn runs over the whole span, slow at both ends and fastest in the middle.
  `tilt` and `roll` ease in and out as in `hold`.
- **Parameters:** `tilt`, `roll` as `hold`. `turn` is ignored: the turn is always 360°. A span of 3–5 s reads well; under 2 s it whips.
- **Limits:** as `hold`. Half way the screen faces away: nothing on it can be read.
- **Use:** at most once, in an open or a close. **Avoid:** anywhere the screen must be read.

### `mask`

![mask styles](effects/mask-styles.png)

*`blur`, `pixels`, and `solid` with `radius` 0.3, one frame each.*

Hides a fixed part of the recording. [edits.md](edits.md#masks) has how to measure its `rect`.

- **Sees:** a rectangle of the recording replaced on every frame of its span.
- **Timing:** none: full strength from `start` to `end`, a few milliseconds early and late.
- **Limits:** applied to the recording itself, first, so it follows zooms, moves and 3D, and no
  effect weakens it. The drawn cursor shows over it. Masks never clash with each other or anything else.

Its `style`:

#### `blur`

- **Sees:** a soft smear of the colours under it; the default. Big cells first, then a deep blur, so no detail survives.
- **Use:** to hide a secret quietly.

#### `pixels`

- **Sees:** large square cells, a sixth of the box's short side, at least 28 recorded pixels.
- **Use:** when it should read as "censored".

#### `solid`

- **Sees:** a flat box in `color` (`#RRGGBB` or a text colour's name; default black).
- **Use:** a clean redaction bar; match `color` to the UI to make it disappear.

All three take `radius` (0–0.5 of the box's short side) for rounded corners.

## Whole-frame reach

`blur` and `mono` take a `scope`: a cut in the stack background, video, images, texts (back to
front). It covers every layer under the cut. Any `scope` but `"video"` sits on the whole-frame lanes.
Two with different reaches may overlap. To cover one image or one text alone, use its own effects
([Image effects](#image-effects), [Text effects](#text-effects)).

### `video`

The default (no `scope`): only the video, as above.

### `background`

![blur over the background](effects/blur-background.png)
![black and white over the background](effects/mono-background.png)

*Frames 0.8–1.6 s, on the `sunset` background. A gradient barely changes under a blur; a `"video"` background shows it.*

- **Sees:** only the background blurs or goes grey; the video, the images and the texts stay as they are.
- **Timing:** as `frame`.
- **Use:** a grey background to make a colourful screen stand out. **Avoid:** a blur on a plain gradient: nothing shows.

### `scene`

![blur over the background and the video](effects/blur-scene.png)
![black and white over the background and the video](effects/mono-scene.png)

*Frames 0.8–1.6 s. The image and the text stay sharp and in colour.*

- **Sees:** the background and the video blur or go grey; images and texts stay on top, sharp.
- **Timing:** as `frame`.
- **Use:** under a title and a logo in the first beat: the brand stays crisp. **Avoid:** on a key point.

### `frame`

![blur over the frame](effects/blur-frame.png)
![black and white over the frame](effects/mono-frame.png)

*Frames 0.8–1.6 s. The image goes too; the text stays sharp and in colour.*

- **Sees:** the whole picture (background, video and images) blurs or goes grey; texts stay on top, sharp.
- **Timing:** eases in and out over 0.3 s. Its blur is a little stronger than the video's.
- **Use:** behind a title card or a closing line. **Avoid:** with long texts: the frame stays still and dull.

### `all`

![blur over everything](effects/blur-all.png)
![black and white over everything](effects/mono-all.png)

*Frames 0.8–1.6 s. The text goes too.*

- **Sees:** everything, texts included.
- **Timing:** as `frame`.
- **Use:** a blur into the last beat, or out of the first. **Avoid:** while a text must be read.

## Transitions

Between two kept parts with removed parts between, keyed by the earlier part's end in `transitions`.
No key is a plain cut.

### `crossfade`

![crossfade](effects/transition-crossfade.png)

*A cut at 3 s; video frames 2.3–3.1 s. The video sits left before the cut and right after.*

- **Sees:** the frame before the cut dissolves into the frame after it, the background too.
- **Timing:** 0.6 s, eased, ending where the earlier part ends; shorter when either part lasts under
  1.2 s of video (half of it). The video gets that much shorter. The recorded sound crossfades too.
- **Limits:** texts and images are drawn once over the blend, at the later part's time.
- **Use:** where time jumps and the screen changes a lot. **Avoid:** a different transition on every cut.

### `fade`

![fade](effects/transition-fade.png)

*A cut at 3 s; video frames 2.5–3.5 s.*

- **Sees:** the video fades out over the background, then the next part fades in. The background
  stays; texts and images stay.
- **Timing:** 0.4 s out at the end of the earlier part and 0.4 s in at the start of the later one,
  eased. The length does not change. The recorded sound dips with it.
- **Use:** between chapters, or into the close.

## Move styles

A move lands the video (or, in an image's `moves`, the image) at `to` at `t`, travelling over the
`duration` before it (default 0.8 s). Before the first move the video is at `base`. Moves should not
overlap: a later move that starts before an earlier one lands jumps to its own progress when the
earlier one lands. Each strip: `base` → x 0.3, y 0.55, scale 0.55 landing at 3 s after 1.5 s,
frames 1.4–3.2 s.

With 3D on, a move's `angles` turn the video as it travels, eased as its style says. With 3D off
they are ignored.

### `smooth`

![smooth](effects/move-smooth.png)

- **Sees:** glides to the new place and size. The default.
- **Timing:** eased in and out (slow, fast, slow).
- **Use:** to change sides between chapters.

### `linear`

![linear](effects/move-linear.png)

- **Sees:** travels at one steady speed, starting and stopping abruptly.
- **Use:** a slow drift or push over several seconds, where the abrupt ends are not seen. **Avoid:** short moves.

### `spring`

![spring](effects/move-spring.png)

- **Sees:** shoots toward the new place, passes it a little and settles back; the angle springs too.
- **Use:** a lively change of sides, or an entrance from off the frame.

### `zoom`

![zoom through](effects/move-zoom.png)

- **Sees:** grows until it covers the whole frame at its centre, then shrinks into the new place.
  In 3D it is face on while it fills the frame. An image's zoom move grows the image to cover the frame too.
- **Timing:** each half eased, half the duration each.
- **Use:** at most once, at a chapter change. Loud.

### `swipe`

![swipe](effects/move-swipe.png)

- **Sees:** slides out past the frame's edge in the direction of travel, and comes back in from the
  opposite side into the new place (to the right when the place stays the same). Its size and angle jump while it is off the frame.
- **Timing:** out eased in and out over the first half, in easing out over the second.
- **Use:** at most once, at a chapter change. Loud.

### `fade`

![fade move](effects/move-fade.png)

- **Sees:** fades out where it is, then fades in at the new place and size; the angle jumps half way.
- **Timing:** half the duration out, half in.
- **Use:** to jump to a new layout quietly.

### `spin`

![spin](effects/move-spin.png)
![spin in 3D](effects/move-spin-3d.png)

*Top: 3D off. Bottom: 3D on, landing at the centre with `angles` tilt 8.*

- **Sees:** 3D off: one full turn in the picture's plane while it travels, shrinking by up to 30% half
  way. 3D on: one full turn about the vertical axis instead (its back shows half way), with the same dip.
- **Timing:** eased in and out.
- **Use:** at most once, in a playful piece. **Avoid:** in a calm voice; on a screen that must be read.

### `pop`

![pop](effects/move-pop.png)

- **Sees:** shrinks to 82% as it sets off, travels, and springs back to full size with a bounce on arrival.
- **Timing:** shrinks over the first 30%, springs back over the last 40%.
- **Use:** at most once, at a chapter change.

![3D angles on a smooth move](effects/move-3d-angles.png)

*3D on: a `smooth` move to `angles` tilt 15, turn 30.*

## 3D edges

`three.edge` is the finish of the slab's sides while the video is in 3D (3D on, or a 3D turn). The
back is always near black. `three.thickness` is its depth as a share of its width (default 0.05;
0.01–0.15 reads). Nothing shows of either while the video faces the camera square.

### `metal`

Dark grey, shiny metal. The default; suits any device.

### `aluminum`

Light grey, satin metal. Suits a light UI or a silver device.

### `glass`

Near white and glossy, not metal. Suits a bright, airy look.

### `matte`

Near black and rough, with no shine. Suits a dark UI; the quietest.

## Text entrances

`animIn`: how a text appears. Default `pop`; `none` shows it at once. The whole-text entrances take
0.55 s. The letter-by-letter ones start each letter a little after the last (at most 0.045 s, and
0.6 s spread across the line), so a long line takes up to about 1.2 s. A `pill` or `box` comes with
the first letter.

Each strip: a `heavy` `pill` text "Hello world" from 1 s, frames from 1 s.

### `fade`

![text fade in](effects/text-in-fade.png)

- **Sees:** fades in where it is. **Use:** the calmest; any line.

### `pop`

![text pop in](effects/text-in-pop.png)

- **Sees:** grows from nothing, overshoots a little and settles, fading in fast. The default.
- **Use:** a short, lively line.

### `rise`

![text rise in](effects/text-in-rise.png)

- **Sees:** rises by about half its height into place while fading in. **Use:** calm key-point lines.

### `blur`

![text blur in](effects/text-in-blur.png)

- **Sees:** comes into focus from a blur while fading in. **Use:** calm key-point lines.

### `spin`

![text spin in](effects/text-in-spin.png)

- **Sees:** turns a quarter turn into place while growing from nothing. **Avoid:** unless the voice is playful.

### `slide`

![text slide in](effects/text-in-slide.png)

- **Sees:** slides in from the left (from 40% of the frame's width away) and settles with a small bounce.
- **Avoid:** near the left edge, where it starts outside the frame.

### `letters`

![text letters in](effects/text-in-letters.png)

*Frames 1–2.1 s.*

- **Sees:** each letter springs up from below, left to right, with a little bounce.
- **Timing:** each letter 0.5 s. **Use:** one title at most.

### `letters-pop`

![text letters-pop in](effects/text-in-letters-pop.png)

*Frames 1–2.1 s.*

- **Sees:** each letter grows from nothing with a bounce, left to right.
- **Timing:** each letter 0.45 s. **Use:** one title at most.

### `drop`

![text drop in](effects/text-in-drop.png)

*Frames 1–2.1 s.*

- **Sees:** each letter drops from well above (1.6× its height) and bounces into place, left to right.
- **Timing:** each letter 0.6 s. **Avoid:** unless the voice is playful.

### `typewriter`

![text typewriter in](effects/text-in-typewriter.png)

*Frames 1–2.1 s.*

- **Sees:** letters appear one at a time with no fade, as typed.
- **Timing:** 0.06 s per letter, spaces included, with no cap: 30 letters take 1.8 s. Add that to the reading time.
- **Avoid:** unless the voice is playful, and on long lines.

## Text exits

`animOut`: how a text leaves, ending at its `end`. Default `fade`; `none` cuts it. The whole-text
exits take 0.45 s; the letter ones up to about 0.9 s. A text shorter than its entrance plus its exit
is never fully shown.

Each strip: a text ending at 3 s, frames 2.4–2.98 s.

### `fade`

![text fade out](effects/text-out-fade.png)

- **Sees:** fades out where it is. The default. **Use:** any line.

### `pop`

![text pop out](effects/text-out-pop.png)

- **Sees:** shrinks to nothing while fading. **Use:** with a `pop` entrance.

### `sink`

![text sink out](effects/text-out-sink.png)

- **Sees:** sinks by about half its height while fading. **Use:** with a `rise` entrance.

### `blur`

![text blur out](effects/text-out-blur.png)

- **Sees:** blurs away while fading. **Use:** calm lines; pairs with a `blur` entrance.

### `fall`

![text fall out](effects/text-out-fall.png)

- **Sees:** letters tip over, alternately left and right, and fall while fading, left to right.
- **Timing:** each letter 0.5 s, up to about 0.9 s for the line. **Avoid:** unless the voice is playful.

### `letters`

![text letters out](effects/text-out-letters.png)

- **Sees:** letters fade out one by one, left to right.
- **Timing:** each letter 0.3 s, up to about 0.65 s for the line. **Use:** with a `letters` entrance.

## Text loops

`loop`: a motion while the text shows, from its start, on top of the entrance and exit. Default `none`.
A joined text keeps its phase across the cut. Each strip: frames 2–3.4 s.

### `wave`

![text wave](effects/text-loop-wave.png)

- **Sees:** letters bob up and down in a wave running left to right, by 8% of the text's height, every 1.2 s.

### `pulse`

![text pulse](effects/text-loop-pulse.png)

- **Sees:** the text grows and shrinks by 4.5%, every 1.4 s.

### `float`

![text float](effects/text-loop-float.png)

- **Sees:** the text drifts up and down by 8% of its height, every 2.4 s.

### `wiggle`

![text wiggle](effects/text-loop-wiggle.png)

- **Sees:** the text rocks about 3° each way, every 1.1 s.

All four: **use** only on a call to action; **avoid** on a line that must be read calmly.

## Text styles

`style`: the shape behind or around the letters. Default `plain`. Texts are drawn over everything
but a whole-frame effect with `scope` `"all"`: zooms, moves and video effects never touch them.

![text styles](effects/text-styles.png)

*`plain`, `pill`, `box`, `outline`, `shadow` on a mid-grey background.*

### `plain`

Letters only. Reads only on a calm background of good contrast.

### `pill`

A fully rounded capsule behind the letters: dark at 62% behind light text, white at 92% behind
`black` text. Reads over anything; the safest choice.

### `box`

As `pill`, with slightly rounded corners.

### `outline`

A thin stroke around each letter: black around light colours, white around `black`.

### `shadow`

A soft drop shadow under the letters. Lifts light text off a busy background.

## Text weights

`weight`: the system font's weight. Default `bold`.

![text weights](effects/text-weights.png)

| weight | sees |
|---|---|
| `regular` | plain, light; for a subline |
| `bold` | the default |
| `heavy` | thick, for titles |
| `rounded` | bold with rounded ends (SF Rounded); friendly |

## Text colours

`color`: the letters' colour. Default `white`. Only `black` counts as dark: the backing of `pill` and
`box` and the stroke of `outline` turn light behind it.

![text colours](effects/text-colors.png)

| color | sees |
|---|---|
| `white` | pure white; the default, for dark backgrounds |
| `black` | for light backgrounds |
| `yellow` | warm yellow; only on dark |
| `pink` | strong pink; only on dark |
| `blue` | bright blue; only on dark |
| `mint` | light green; only on dark |

`size` is the font size as a share of the frame's height (default 0.08). `rotation` turns the text
clockwise, in degrees.

## Image entrances

An image's `animIn`. Default `fade` when the key is missing (`./exact-studio image` writes `pop`);
`none` shows it at once. 0.55 s. Each strip: the picture centred at `size` 0.35 from 1 s, frames 1–1.6 s.

### `fade`

![image fade in](effects/image-in-fade.png)

- **Sees:** fades in. **Use:** a logo or a screenshot.

### `pop`

![image pop in](effects/image-in-pop.png)

- **Sees:** grows from nothing, overshoots a little and settles. **Use:** a badge or a sticker.

### `rise`

![image rise in](effects/image-in-rise.png)

- **Sees:** rises by 30% of its height while fading in.

### `slide`

![image slide in](effects/image-in-slide.png)

- **Sees:** slides in from the left (40% of the frame's width) with a small bounce.

### `spin`

![image spin in](effects/image-in-spin.png)

- **Sees:** turns a quarter turn into place while growing. **Avoid:** unless the voice is playful.

### `blur`

![image blur in](effects/image-in-blur.png)

- **Sees:** comes into focus while fading in.

## Image exits

An image's `animOut`, ending at its `end`. Default `fade`. 0.45 s. Each strip: an image ending at 3 s,
frames 2.55–2.98 s.

### `fade`

![image fade out](effects/image-out-fade.png)

- **Sees:** fades out.

### `pop`

![image pop out](effects/image-out-pop.png)

- **Sees:** shrinks to nothing while fading.

### `sink`

![image sink out](effects/image-out-sink.png)

- **Sees:** sinks by 30% of its height while fading.

### `blur`

![image blur out](effects/image-out-blur.png)

- **Sees:** blurs away while fading.

## Image effects

An image's own `effects`: each touches only that image and eases in and out over 0.3 s (a motion
grows and shrinks with that ease). Two of one kind never overlap on one image. Each strip: an
effect from 2 s on the centred picture.

### `blur`

![image blur](effects/image-effect-blur.png)

- **Sees:** the picture goes soft, by 6% of its height. **Use:** to push a picture back behind a text.

### `mono`

![image black and white](effects/image-effect-mono.png)

- **Sees:** the picture goes black and white.

### `fade`

![image fade](effects/image-effect-fade.png)

- **Sees:** the picture fades to `level` (an opacity, 0–1, default 0.3) and back.
- **Use:** to dim a picture while something else speaks.

### `pulse`

![image pulse](effects/image-effect-pulse.png)

- **Sees:** grows and shrinks by 6%, every 1.4 s.

### `float`

![image float](effects/image-effect-float.png)

- **Sees:** drifts up and down by 5% of its height, every 2.4 s.

### `wiggle`

![image wiggle](effects/image-effect-wiggle.png)

- **Sees:** rocks about 3.4° each way, every 1.1 s.

The three motions: **use** on a call to action or a sticker; **avoid** on a logo or a screenshot.

Images move with the [move styles](#move-styles) above, in their own `moves`: no angles, and a `spin`
turns them in the picture's plane.

## Text effects

A text's own `effects`: as an image's, each touches only that text and eases in and out over 0.3 s.
Two of one kind never overlap on one text. Each strip: an effect from 2 s on a centred text.

### `blur`

![text blur](effects/text-effect-blur.png)

- **Sees:** the words go soft, by 22% of their height: unreadable. **Use:** to hide a line until its moment, or
  to push it back while another text speaks.

### `mono`

![text black and white](effects/text-effect-mono.png)

- **Sees:** the text and its shape go black and white.

### `fade`

![text fade](effects/text-effect-fade.png)

- **Sees:** the text fades to `level` (an opacity, 0–1, default 0.3) and back.
