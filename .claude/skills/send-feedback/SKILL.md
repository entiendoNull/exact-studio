---
name: send-feedback
description: Exact Studio takes feedback through GitHub issues and pull requests on entiendoNull/exact-studio. Use while recording or editing with Exact Studio (its app, ./exact-studio, or the MCP server) when you or the owner hit a bug, a confusing verb, field or doc, or a missing feature. Note it, ask the owner at a natural break, and file an issue or prepare a pull request only after they say yes. Also use when the owner asks to report a bug or request a feature in Exact Studio.
---

# Feedback to Exact Studio

Exact Studio is open source: <https://github.com/entiendoNull/exact-studio>. Bugs and ideas go in
issues; fixes come as pull requests (CONTRIBUTING.md). Agents use the tool more than anyone, so what
you hit is worth sending, **but only when the owner says so.**

This is about Exact Studio itself. Trouble with the Exact framework while building the app goes
through `bun exact.mjs feedback note` instead (AGENTS.md).

## The rule

**Never file, comment, fork, push or open a pull request without the owner's explicit yes for that
item.** A yes to one item is not a yes to the others. Show them the exact text first.

## 1. Notice and note

Note an item when:

- **Bug**: a crash; `validate` says `ok` but the frame or export is wrong; a verb fails where the docs
  say it works; the app and `frame` disagree; a field does not do what `docs/edits.md` says.
- **Confusion**: a doc or verb you misread, something that took several tries, an error that did not
  say what to do.
- **Missing feature**: something the edit needed that the model cannot express, and the workaround
  you used.

For each, keep: one line of what happened, the steps or the command, what you expected, what you got,
and the workaround. Keep the list in the conversation; do not write it into the repository or the
recording's folder.

## 2. Ask at a natural break

Do not interrupt the task. Collect items and ask **once**: at the end of the task, at the handover,
or when the owner pauses. Ask right away only when the item blocks the task.

Ask in plain words, one line per item, with a proposed action:

> While editing I hit two things in Exact Studio:
> 1. Bug: `frame` draws a text off the frame edge although `validate` says ok. Should we open an issue?
> 2. Confusing: zooms always centre on the cursor, so I could not zoom on a tap away from it. I think a
>    zoom target point would help. Should we let them know?
> I can show you the text before anything is sent.

If the owner says no, drop it and do not ask again in this session.

## 3. Check for duplicates

```sh
gh auth status
gh issue list -R entiendoNull/exact-studio --state all --search "<two or three key words>"
gh issue view <number> -R entiendoNull/exact-studio
```

Search with a few wordings (the verb, the field, the symptom). If one matches, offer to add a
comment with what is new (`gh issue comment <number> -R entiendoNull/exact-studio --body-file <file>`),
again only after a yes. If `gh` is not signed in, give the owner the text and
<https://github.com/entiendoNull/exact-studio/issues/new>.

## 4. Write a good report

Short title that names the symptom: `frame: long text runs past the frame edge`. Body:

```markdown
**What happened**
One or two sentences.

**Steps**
1. `./exact-studio …`
2. …

**Expected**
…

**Actual**
… (the exact error text)

**Environment**
- macOS: <sw_vers -productVersion>, <uname -m>
- exact-studio: <git rev-parse --short HEAD> on <branch>
- exact: <git -C ../exact rev-parse --short HEAD>
- Through: the app / ./exact-studio / the MCP server
- Xcode: <xcodebuild -version> (build problems only)

**edits.json** (the smallest part that shows it)
```

- Make it reproducible with the smallest `edits.json` part: one segment, not the whole file.
- For a feature request: the goal, what you tried, the workaround, and the smallest change that would
  help. One request per issue.
- Label: `bug`, `enhancement` or `documentation`. If `gh` refuses the label, file without it.

**Privacy.** A report is public. Without the owner's consent for that item, never include: frames,
exports or `capture.mov`; recording names; on-screen text, product names or copy from `edits.json`;
file names of their images and sounds; anything a mask hides. Replace paths under `/Users/<name>` with
`~`, and invented values (`"text": "Hello"`) for real copy. When a frame would help, ask before
attaching it, and say what it shows.

## 5. File it

After the owner approves the text:

```sh
gh issue create -R entiendoNull/exact-studio --title "<title>" --body-file <scratch>/issue.md --label bug
```

Give the owner the issue's link.

## 6. A pull request, when the owner wants to fix it

Only for a small, clear fix the owner asks for. Follow CONTRIBUTING.md:

1. Work from a fork: `gh repo fork entiendoNull/exact-studio --remote` (skip it if `origin` is
   already the owner's fork, or they can push to entiendoNull/exact-studio). Never push to `main`.
2. Branch from an up-to-date `main` with a short name: `fix-text-overflow`.
3. Read the LLP for the part you change (`llp/0000-exact-studio.explainer.md` maps them). A changed
   decision updates its LLP in the same pull request. A feature reaches the CLI, the MCP server,
   `docs/edits.md`, the schema and the edit-recording skill together (LLP 0004).
4. Run `bun exact.mjs test` and `./ref-check`; run the app and try the change.
5. Show the owner the diff and the description, then, on their yes:
   `gh pr create -R entiendoNull/exact-studio --base main --title "<title>" --body-file <file>`, with the
   template's sections (What changed; How I tested it) and `Fixes #<issue>` when there is one.
6. One change per pull request. Give the owner the link.
