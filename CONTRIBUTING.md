# Contributing to Exact Studio

Changes reach `main` through pull requests. Nobody pushes to `main` directly.

## What you need

- A Mac with Apple silicon and macOS 14 or later.
- Xcode 27. The build works with Xcode 27.2 and fails with Xcode 26.6.
- [Bun](https://bun.sh).
- A checkout of [expo/exact](https://github.com/expo/exact) beside this one. The app builds against it by path.

## Set up

Fork this repository on GitHub, then clone your fork and Exact into the same folder:

```sh
git clone git@github.com:<you>/exact-studio.git
git clone git@github.com:expo/exact.git
cd exact-studio
bun ../exact/scripts/exact.mjs setup
```

`setup` installs the Rust toolchain and the other tools that Exact pins. `bun ../exact/scripts/exact.mjs setup --check` lists what is missing without installing anything.

If your Exact checkout is somewhere else, set `EXACT2` to its path.

## Run the app

```sh
bun exact.mjs mac --run
```

The first build takes several minutes. The first recording asks for Screen Recording permission in System Settings › Privacy & Security. Reopen the app after you allow it.

## Make a change

1. Create a branch from `main` with a short name, for example `fix-crop-handles`.
2. Read the design note for the part you change. The notes are in [`llp/`](llp), and they start at [`llp/0000-exact-studio.explainer.md`](llp/0000-exact-studio.explainer.md). An `@ref LLP NNNN#section` comment in the code names the note behind that code.
3. Make the change. If it changes a decision, update the note in the same pull request.
4. Add a test for the change. Every bug fix and every feature adds one (see below).
5. Run the checks: `./check`. It must pass.
6. Run the app and try your change.
7. Open a pull request against `main`.

Do not edit `exact.mjs` or the generated block at the top of `AGENTS.md`. `bun exact.mjs update` writes them.

## Run the checks

```sh
./check           # everything, about 40 s after the first build
./check --fast    # without the macOS UI tests, about 10 s
```

`./check` does not stop at the first failure. It runs every part, prints each part's time, and exits 1 when a part fails.

| Part | What it checks | Where |
|---|---|---|
| `./ref-check` | The design notes and the `@ref` comments | `llp/` |
| `contract build` | The view compiles | `app.contract` |
| Edit model and Editor | Lane rules, cuts, the time map, templates, old files; the Editor's split, remove, join, add, drag, delete, templates and undo, on a real video | `test/model/main.swift` |
| CLI | `validate` and `show` on the fixture recordings against goldens, the JSON Schemas, `frame`, `strip`, `template`, `image`, `sound`, `mask` | `test/cli.test.ts`, `test/fixtures/`, `test/golden/` |
| MCP server | Its tools and a `write_edits` round trip | `test/mcp.test.ts` |
| Effects reference | Every effect, style and animation name the code accepts has an entry in `docs/effects.md`; its picture strips exist | `test/effects.test.ts`, `docs/effects/` |
| macOS UI | The empty app; the editor on fixture recordings: the timeline, the inspector, templates | `app.test.contract`, `test/ui/*.test.contract` |

### Add a test

Every bug fix and every feature adds a test that fails without it. Put it at the lowest level that shows the behaviour:

- A rule of the edit files (a lane rule, a cut, a field): a test in `test/model/main.swift`, or a fixture.
- A problem `validate` must report: a folder in `test/fixtures/invalid/<name>/` with a `meta.json` and the bad `edits.json`. The first run writes `test/golden/validate/<name>.txt`. Read it, then commit it.
- What `show` prints: a folder in `test/fixtures/valid/`. Its goldens are written the same way.
- What an Editor action does (the timeline's buttons and menus call these): a test in `test/model/main.swift` that opens a fixture with `open(…)`.
- What the window shows or does: a test in `test/ui/editor.test.contract`. It runs on the fixture recordings, each test from a fresh copy.

A new effect, style or animation needs an entry in `docs/effects.md`. When a change alters how anything draws, run `test/make-effect-strips.sh`, look at the strips in `docs/effects/`, then commit them.

When an output changes on purpose, run `./check --update` and read the diff of `test/golden/` before you commit it.

Fixtures hold no video. `./check` makes a small `capture.mov` in `.exact/test/` and copies `test/fixtures/media/` into each recording.

The UI tests click the timeline at fixed points (`tap "timeline" drag 0 0 from x y mouse`) in a 1440×900 window. A change to the timeline's layout can move a row; then update the points.

## Pull requests

- Keep each pull request to one change.
- Say what changed and how you tested it. Add a screenshot or a short video when the change is visible.
- A maintainer reviews and merges it.

## Report a bug or ask for a feature

Open an [issue](https://github.com/entiendoNull/exact-studio/issues). For a bug, give the macOS version, the steps, and what you expected.

## License

Exact Studio uses the [MIT license](LICENSE). Your contributions use the same license.
