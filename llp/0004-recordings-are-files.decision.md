# LLP 0004: Recordings are files, so agents can edit them

**Type:** Decision
**Status:** Active
**Systems:** Library, CLI
**Author:** Jacob Clausen / Claude
**Date:** 2026-11-12
**Related:** LLP 0000, LLP 0002, LLP 0003, LLP 0007

Decided by Jacob while building v1 (2026-11-11), after a colleague asked whether agents can edit
the timeline. Answer: yes, and this is vital.

## The rule

A recording is a folder of plain files. The timeline is `edits.json`; the frame is `look.json`.
Anything you can do in the UI, you can do by editing those files. Keep it that way: no edit state
that only lives in the app.

This is the app's first purpose, and the README says so at its top: agents edit the videos as well
as a person does. A feature is not done until the command-line tool, the MCP server, the format
guide, the schema and the editing skill have it too.

- The app watches the files and shows a change within a second.
- Files are saved pretty-printed with sorted keys, so diffs stay readable.
- The format is in [`docs/edits.md`](../docs/edits.md). The schemas are in `schema/`.
- A picture an edit uses is copied into the recording's `images/` folder, and `edits.json` names it
  by its path inside the recording. `./exact-studio image` (and the MCP tool `add_image`) do the copy.
- A sound file goes into `sounds/` the same way. `./exact-studio sound` (and `add_sound`) do the copy,
  for an added sound or for the recorded sound (`--as-recorded`, LLP 0002#sound).

## The CLI

`./exact-studio` (list, show, validate, frame, export, template, image, sound, mask, schema) builds from the app's own
renderer sources (LLP 0003), so a frame from the CLI is the frame the app exports.
`sources` and `record start|status|stop` ask the running app to record (LLP 0007).
The `edit-recording` skill in `.claude/skills/` is the workflow for agents. Beside it, `direct-recording`
is the craft (what to cut, emphasise and say in a promo) and `send-feedback` how an agent reports a
problem with Exact Studio, only after the owner agrees. The MCP server returns both
(`directing_guide`, `feedback_guide`), as `edit_format` returns the format, so an agent outside
this folder gets them too.

## Opening

- File ▸ Open Recording… (⌘O, also "Open…" in the sidebar) picks a recording folder: the one with `meta.json`.
- A folder already in the library is selected. A folder from somewhere else is copied into the library first, under its id.
- If the library already has that id, the copy in the library wins. Nothing is overwritten.

## Reading the files

- `docs/edits.md` and `schema/` decide what a valid file is. The Swift reader accepts every file they accept.
- A key the format calls optional takes its documented default: a segment's `lane` 0, a move's `style`
  `smooth` and `duration` 0.8, a missing `x` or `y` of `base` or `to` 0.5 and `scale` 1, a missing angle 0.
- Swift's synthesized `Decodable` ignores a property's default value, so each model type with one
  decodes by hand (`Segment`, `Placement`, `Move`, `Angles`, `Sound`, `ThreeD`, `Look`, `Edits`).
- `validate` refuses what the code refuses, and the schema says the same: a mask's `style` is an enum.

## A file that cannot be read

Decided 2026-11-18, after a file the reader was too strict for opened empty and the next change saved over it.

- A missing `edits.json` or `look.json` is a fresh start. A file that exists and does not decode is never written over.
- The app opens the recording empty (or with the last look), shows why in the inspector, and refuses every
  change to that file. A change to the other file still saves.
- When the file is fixed on disk, the app reads it within a second and saves again. No backup copy: the file
  itself is never touched, so there is nothing to restore.
- The CLI: every verb but `validate` stops with exit 1 and writes nothing. `validate` lists why.
  `show --json` gives the folder and the problems under `unreadable`, so the MCP server's `read_edits` and
  `write_edits` can still reach the file to repair it.
