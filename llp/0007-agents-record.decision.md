# LLP 0007: Agents record through the running app

**Type:** Decision
**Status:** Active
**Systems:** Capture, CLI, MCP
**Author:** Jacob Clausen / Claude
**Date:** 2026-11-14
**Related:** LLP 0001, LLP 0004, LLP 0006

Asked for by Jacob on 2026-11-14. Agents record without a person: list the sources, start, read the
status, stop, and go on editing the new recording. People use agents to edit videos, so the skill, the
CLI and the MCP server must all do this well.

## Who records

- The app records, never the CLI. The CLI and the MCP server ask the running app to start and stop.
- Why: Screen Recording permission belongs to the app's bundle. A CLI that records by itself would ask
  for the permission for the terminal or the agent's host, and would record with no red menu bar mark.
- So an agent's recording looks like a person's: the red mark with the time, one click stops it, and the
  finished recording is selected. There is no new UI.
- When the app is not running, `sources` and `record start` open it in the background (`open -g -b`,
  or `EXACT_STUDIO_APP`) and wait up to 30 s for it to answer. `record status` and `record stop` never open it.

## The channel

- A private folder: `~/Library/Application Support/Exact Studio/control/`. No network, no socket.
- The app writes `app.json` there with its pid when it starts, and removes it when it quits.
- A request is `requests/<id>.json`: `op` (`sources`, `status`, `start`, `stop`), its arguments, and
  `expires` (seconds since 1970). The answer is `replies/<id>.json`. Each file is written to a temporary
  name, then renamed, so nobody reads half a file.
- The app watches `requests/`, takes each file, and drops one that expired: a late app never starts a
  recording the agent already gave up on.
- The CLI waits for the answer: 15 s for sources, 30 s for start, 10 s for status, 60 s for stop. On a
  timeout, it takes its request back and says whether the app ever took it.
- Only the app that `app.json` names answers. A second copy of the app never starts a second recording.
- `EXACT_STUDIO_CONTROL` names another folder, for tests against a fake app. Then the CLI never opens
  the app, since an app opened by Launch Services serves only the default folder.
- Under `bun exact.mjs agent`, the app serves `control/` in its scratch library instead. A drive never
  answers the person's tools.

## Same user only

- The folder and its two subfolders are 0700; the files are 0600.
- The app and the CLI refuse a folder that is a link, that another user owns, or that others can still
  open after a chmod. They read only plain files this user owns.

## Names

- `sources` lists what the pickers would offer, from the same lists: displays, Simulators and
  emulators, then other apps' windows. Never the app's own windows.
- Each gets a name `record start` takes: `display:1` (in the list's order), `simulator:<window title>`
  (the name the sidebar shows), `window:<App — Title>`. Two with one name get `window:#<window number>`.
- `record start` also takes a unique part of a name, and `area:x,y,w,h[@<display>]` in points from the
  display's top-left corner.
- No match, or more than one, is refused, and the candidates are listed. The matching is a pure
  function on the app's list (`SourceMatch` in `Control.swift`), so it is tested without the app.
- A start records the same `window:<id>` or `display:<id>` the pickers end in, through the same
  `Recorder.make`. So a Simulator is cropped to the phone and a window keeps its shape (LLP 0001).
- No picker shows: an agent's start is immediate.

## Never take over

- A start is refused while a recording runs, while one is starting, and while a person has a picker open.
  Nothing running is stopped or replaced.
- `record stop` stops only a recording an agent started. One started in the app is left running, unless
  the agent passes `--any` (`any: true`) because the person asked it to.
- A start without the Screen Recording permission is refused, and says a person must allow it.
- `--max <seconds>` stops the recording by itself, in case the agent never calls stop.
- `--sound on|off` overrides the app's System Sound setting for this recording only.

## Exit codes

- 0: done. 1: refused (busy, no match, not recording). 2: a usage mistake.
- 3: a person must act (the Screen Recording permission). 4: the app could not be reached in time.
- The MCP tools add what to do next for 3 and 4, and the next tools to call after a stop.
