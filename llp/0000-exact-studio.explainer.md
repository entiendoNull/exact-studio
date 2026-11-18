# LLP 0000: Exact Studio

**Type:** Explainer
**Status:** Active
**Systems:** Core
**Role:** Root
**Author:** Jacob Clausen / Claude
**Date:** 2026-11-12
**Related:** LLP 0001, LLP 0002, LLP 0003, LLP 0004, LLP 0005, LLP 0006, LLP 0007

Start here. Then read the doc for the part you change.

## What it is

A Mac screen recorder and editor, built with Exact. It has one main
goal: a recording of an iOS Simulator or Android emulator is cut to the phone itself, and nothing
more. You can also record a window or an area you draw.

It is a hobby project. Fewer rules, less ceremony. Ship it, see it, change it.

## How it fits together

```
capture  →  recording folder  →  editor  →  renderer  →  preview / export / CLI
```

| Part | Where | Doc |
|---|---|---|
| Capture: sources, area picker, recorder, bezel finding | `modules/apple/Capture.swift`, `Bezel.swift` | [LLP 0001](./0001-capture-and-device-crop.decision.md) |
| The edit model: clips, lanes, images, sounds, Position, look | `modules/apple/Compositor.swift` (types), `Images.swift`, `Sounds.swift`, `Editor.swift` | [LLP 0002](./0002-timeline-and-edit-model.decision.md) |
| Rendering, 3D, templates | `Compositor.swift`, `Scene3D.swift`, `Templates.swift` | [LLP 0003](./0003-one-renderer-and-3d.decision.md) |
| Files as the API, CLI for agents | `cli/main.swift`, `exact-studio`, `docs/edits.md`, `schema/` | [LLP 0004](./0004-recordings-are-files.decision.md) |
| The UI | `app.contract`, `app.ts`, `Timeline.swift`, `Studio.swift` | [LLP 0005](./0005-ui.principles.md) |
| Masks that hide secrets | `Compositor.swift` (`hide`), `Studio.swift` (the box), `cli/main.swift` (`mask`, `frame --raw`) | [LLP 0006](./0006-masks.decision.md) |
| Agents record through the running app | `Control.swift`, `Studio.swift` (`agentRequest`), `cli/main.swift` (`sources`, `record`), `mcp/server.ts` | [LLP 0007](./0007-agents-record.decision.md) |

`app.contract` is the view. `app.ts` talks to the native module. `Studio.swift` is that module:
it takes ops (`edit`, `look`, `export`, …) and hosts the native preview and timeline views.

## Words we use

- **Clip**: the video track. Split it into **parts**; remove parts.
- **Lane**: a row for one kind of thing: the video's effects, texts, sounds, or whole-frame effects. As many as you want.
- **Image**: a picture on top of the video, on an image lane. It has its own Position and Effects rows, shown under its lane.
- **Sound**: the recorded sound, which follows the cuts; or a sound you add (music, an effect), which plays straight through.
- **Mask**: a box on the video that hides a secret with a blur, big pixels or a solid colour. It stays on the content as the video moves.
- **Position**: where the video sits in the frame and how it moves. Its own track.
- **Look**: the frame around the video: background, shape, padding, corners, shadow, cursor.
- **Simulators**: what the sidebar calls devices. Not "Devices".

## Checking your work

- `./check` runs every test and check; it passes before every pull request.
- Every bug fix and every feature adds a test that fails without it, at the lowest level that shows it:
  the edit model or the Editor (`test/model/main.swift`), a fixture for `validate` or `show`
  (`test/fixtures/`), or the window (`test/ui/`).
- The UI tests open fixture recordings from `EXACT_STUDIO_FIXTURES`. Under the agent the timeline's
  folds, lane size and zoom and the last look are fixed, so a drive starts the same way each time.
- `bun exact.mjs mac` builds.
- Drive the app with `bun exact.mjs agent macos` on a copy of a recording. The agent uses a
  scratch library, so your real recordings are safe.
- `./exact-studio frame <id> <t>` renders one frame with the real renderer.
