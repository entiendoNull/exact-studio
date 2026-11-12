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

- The app watches the files and shows a change within a second.
- Files are saved pretty-printed with sorted keys, so diffs stay readable.
- The format is in [`docs/edits.md`](../docs/edits.md). The schemas are in `schema/`.

## The CLI

`./exact-studio` (list, show, validate, frame, export, template, schema) builds from the app's own
renderer sources (LLP 0003), so a frame from the CLI is the frame the app exports.
The `edit-recording` skill in `.claude/skills/` is the workflow for agents.
