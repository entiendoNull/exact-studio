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
4. Run the checks:

   ```sh
   bun exact.mjs test    # the tests in app.test.contract
   ./ref-check           # the design notes and the @ref comments
   ```

5. Run the app and try your change.
6. Open a pull request against `main`.

Do not edit `exact.mjs` or the generated block at the top of `AGENTS.md`. `bun exact.mjs update` writes them.

## Pull requests

- Keep each pull request to one change.
- Say what changed and how you tested it. Add a screenshot or a short video when the change is visible.
- A maintainer reviews and merges it.

## Report a bug or ask for a feature

Open an [issue](https://github.com/entiendoNull/exact-studio/issues). For a bug, give the macOS version, the steps, and what you expected.

## License

Exact Studio uses the [MIT license](LICENSE). Your contributions use the same license.
