<!-- exact:begin (exact new writes this block; bun exact.mjs update rewrites it) -->
# exact-studio: an Exact app

`app.contract` is the view, `app.ts` its data module, `app.test.contract` its tests, `app.json`
the manifest: set its `app.name` and `app.id` before the first build. The app uses the exact2
checkout at `../exact` by path (`EXACT2` overrides it), at the commit in `exact-commit`; `./exact-pin`
checks it. Never pull Exact for this app; moving the pin is its own change (`./exact-pin --set`).

This file is already in your instructions. Start from the nearest pattern: `bun exact.mjs
pattern` lists them and `pattern <name>` writes one, tested. ../exact/docs/start-here-site.md (a site) or
../exact/docs/start-here.md is the only required reading. `bun exact.mjs contract vocab <name>` answers a
name (none: the card); `bun exact.mjs docs <heading words>` a guide's
section. Run `bun exact.mjs verify` when the features work, and `verify ios|android` at the end for a
phone app. When an iPhone app is ready for the person to try, run `bun exact.mjs share` and give
them the link it prints; run it again after each change they should see. `bun exact.mjs help` lists the verbs, and your own in app.json `"commands"`.
`bun exact.mjs update` refreshes files. A native verb (`ios`, `mac`, `linux`, `android`,
`windows`) names its platform in app.json the first time it runs and builds it in a generated
workspace; `update --without <platform>` stops it.
`bun ../exact/scripts/exact.mjs setup --check` names what a native build lacks.
Shared data: `exact new <path> --snapback`, or `bun exact.mjs snapback` here.
Install `snapback4@0.4.33` above; ../exact/snapback4/README.md has setup and server commands.

Generated, so don't edit: `exact.mjs` and this block.

## Feedback (required)

When a doc was wrong or missing, a workaround was needed, something took several tries or a
command confused you, record it: `bun exact.mjs feedback note "<what happened>"`. It attaches
exact2's commit and the last exit code, never output or code. `bun exact.mjs feedback status` says
whether notes are sent and whether to keep a diary; under `never`, skip all of this.
<!-- exact:end -->

## Editing recordings as files

Recordings are folders of plain files: `edits.json` is the timeline, `look.json` the frame. Agents
edit them directly and use `./exact-studio` (list, show, validate, frame, strip, export, template, image,
sound, mask, split) to check and render with the app's own renderer. `./exact-studio sources` and
`record start|status|stop` record without a person, through the running app (LLP 0007).
`docs/edits.md` is the format, `docs/effects.md` what each effect looks like on screen and how it
times; the `edit-recording` skill is the workflow, `direct-recording` the
craft of a promo or demo, and `send-feedback` how to report a bug or idea (only after the owner
says yes). The app reloads changed files within a second.

## Checks and tests

`./check` runs every check: the design notes, the view's compile, the edit model and Editor tests,
the CLI's fixtures and goldens, the MCP server and the macOS UI tests. Run it before every pull
request; `./check --fast` skips the UI tests while you work. CONTRIBUTING.md ("Run the checks")
says what each part covers and where a new test goes.

Every bug fix and every feature adds a test that fails without it (LLP 0000#checking-your-work).

## Design notes (LLP)

Decisions we already made live in `llp/`, as short Linked Literate Programming docs
([ccheever/llp](https://github.com/ccheever/llp)). Start at `llp/0000-exact-studio.explainer.md`.

- Read the doc for the part you change before you change it. `@ref LLP NNNN#section` comments in
  the code point at the reason behind code that looks like it could be simpler.
- When a decision changes, update its doc in the same commit. When you make a new one worth
  keeping, add it to the doc it belongs in, or take the next number.
- Keep the docs short and plain. One idea per line; no essays.
- `./ref-check` checks the docs and the references.
