# LLP 0006: Masks hide what must not be seen

**Type:** Decision
**Status:** Active
**Systems:** Editor, Renderer, CLI
**Author:** Jacob Clausen / Claude
**Date:** 2026-11-14
**Related:** LLP 0002, LLP 0003, LLP 0004

Asked for by Jacob on 2026-11-14. People record screens that show secrets: API keys, emails, names.
A mask hides one part of the video.

## What a mask is

- A segment of kind `mask` on the video's effect lanes, with `start` and `end`, like a blur.
- `rect` is what it hides: `x`, `y`, `w`, `h` in 0–1 of the full recorded frame (before the crop), origin top-left.
- Masks may show at the same time, on separate lanes. They never clash with each other or with other effects.
- A template keeps the masks, as it keeps the images. A template knows nothing of what is secret.

## Follows the video

- The rect is in the full recorded frame, not on the canvas and not in the crop. So the mask stays on
  the same content when the video is placed, moved, zoomed or turned in 3D, and when the crop changes.
- Decided by Jacob on 2026-11-14: at first the rect was in the crop's units. Then a later crop (in the
  app, or an agent editing `meta.json`) slid a mask off its secret. That is a leak.
- Only the part inside the crop is drawn. A mask partly outside the crop hides what is visible of it;
  one fully outside hides nothing, and `show` says so. `validate` only asks that it lies in the frame.
- It is applied to the recording's own pixels, before anything else: before the video's blur and
  black and white, the cursor, the shape, the placement, the zoom and 3D. Nothing later can weaken it.
- The 3D face is drawn from the masked picture, and so is the "video" background.
- The rect does not follow content that moves inside the recording, such as a scrolling page. Use
  several masks, one after another, or a larger one.
- `exact-studio frame <id> <t> --raw` renders the full recorded frame, before the crop, and prints
  where the crop lies. A pixel there divided by its width and height is a point of `rect`. This is how
  an agent finds where a secret is.
- The preview shows the selected mask's box with the crop's handles, where the video is now. A drag
  keeps the box on the visible video. A new mask from the + starts in the middle of the visible video.
  While the video is turned in 3D or spun, there is no box: a flat box cannot follow it.

## Never fades

- A mask is at full strength on every frame from `start` to `end`. It has no ease in or out.
- Why: a fade shows the secret for a few frames, and one frame is enough to read it.
- It is on a few milliseconds early and late, so rounding in the time map never drops a frame.

## Three styles

- `blur` (the default): big cells, then a deep blur. The cells throw away the fine detail that a blur alone keeps.
- `pixels`: big cells, at least 28 recorded pixels, larger for a larger mask.
- `solid`: an opaque fill in `color` (`#RRGGBB`, or a text colour's name), black by default.
- Sizes are in recorded pixels, where 12 pt text is about 24 pixels tall. So 12 pt text is unreadable
  under any mask, at any size. A mask partly outside the crop is sized by the part that shows.
- Only the rect's own pixels go into its blur or cells. Nothing outside is smeared in, and nothing
  inside is smeared out. The fill is opaque, so nothing under it shows through.
- `radius` rounds its corners, as a share of its shorter side, as an image's does.
- All masks are laid over the frame in one step, so every pixel outside them stays exactly as it was.
  A recording without masks renders byte for byte as before (LLP 0003).

## The cursor

The drawn cursor is drawn after the masks, so it shows over a mask. It never shows what is under one.
