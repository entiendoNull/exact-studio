# LLP 0002: Timeline and edit model

**Type:** Decision
**Status:** Active
**Systems:** Editor, Timeline
**Author:** Jacob Clausen / Claude
**Date:** 2026-11-12
**Related:** LLP 0000, LLP 0004

Decided by Jacob while building v1 (2026-11-11).

## Three kinds of rows

- **Clip**: the video. Cuts are clip splits. A split makes a small gap, and you select a part and
  remove it. Kept parts can crossfade or fade into each other.
- **Position**: where the video sits and how it moves (moves and patterns). It is one track,
  because the video can only be in one place at a time. It was called "Motion" before.
- **Lanes**: free rows for zooms, speed, texts, blur, mono, spotlight, highlight and 3D turns.
  Start with zero or add as many as you want. Two effects can run at once on different lanes when
  they don't clash. No lane is special; the first one is "Lane 1", not "Effects".

## What may overlap

- Two segments on one lane never overlap.
- Never two zooms, two speeds, two 3D turns, or two of the same visual effect at one time,
  even on separate lanes. Texts overlap freely.

## Times

Every time in the model is in seconds of the **recording**, not of the edited video. Cuts and
speed don't move your effects. `TimeMap` converts between the two. Templates place things in
video time and convert back, so nothing lands in a removed part.

## Defaults

- A new recording gets **no** automatic zoom. "Zoom on Clicks" is a button you press.
- Start and end times can be typed in text fields.
- Picking a text animation plays it once in the preview.

## Our own look

The split marker is our own: a thin white line with two arrowheads pointing in. Don't copy a
symbol from another app.
