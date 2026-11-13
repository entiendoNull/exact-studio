# LLP 0004: Recordings are files, so agents can edit them

**Type:** Decision
**Status:** Active
**Systems:** Library, CLI
**Author:** Jacob Clausen / Claude
**Date:** 2026-11-12
**Related:** LLP 0000, LLP 0002, LLP 0003

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
- A sound file goes into `sounds/` the same way. `./exact-studio sound` (and `add_sound`) do the copy.

## The CLI

`./exact-studio` (list, show, validate, frame, export, template, image, sound, schema) builds from the app's own
renderer sources (LLP 0003), so a frame from the CLI is the frame the app exports.
The `edit-recording` skill in `.claude/skills/` is the workflow for agents.

## Opening

- File ▸ Open Recording… (⌘O, also "Open…" in the sidebar) picks a recording folder: the one with `meta.json`.
- A folder already in the library is selected. A folder from somewhere else is copied into the library first, under its id.
- If the library already has that id, the copy in the library wins. Nothing is overwritten.
