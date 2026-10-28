# Add kogen starter project command

Slug: k-starter
Model: not applicable — a one-shot scaffolding command; no state machine or interacting rules.
Acceptance:
- .kogen/intents/k-starter/acceptance.feature
- features/steps/k_starter_steps.js

`kogen starter <dir>` creates a small, known-good project from files embedded in the Kogen binary, makes it a Git repository with one commit, and prints the commands to run next. It needs no network and no runtime besides Kogen's own Node and Git. No existing command changes.

## Interface
- `kogen starter <dir>`: exactly one positional argument and no options; a missing or extra argument is the CLI's existing usage error (exit 2). `starter` is added to the top help page (`  starter    Create a starter project to try Kogen on`) and to argument parsing like the other leaf commands.
- Preconditions, both checked before anything is written (target first, then identity), each refused as a Kogen error line with exit 3 and no change on disk:
  - `<dir>` must not exist, or be an existing empty directory. A non-empty directory, or a path that is a file, is refused with `environment/starter_target_not_empty: <dir> already exists and is not empty; choose a new or empty directory (nothing was changed)`.
  - A Git identity (`user.name` and `user.email` configured, global or repository config; the same rule as `Repo.Identity`, evaluated with Git running outside the target) is required. Otherwise `environment/git_identity_missing: no Git identity for the commit; run git config user.name "<name>" and git config user.email "<email>" (global or repository)` (the K21 fix text). Nothing is created, not even an empty `<dir>`.
- Effect: create `<dir>` (parents as needed) and write the embedded files below; `git init` there; stage everything; make exactly one commit with subject `Add Kogen starter project` using the user's own Git configuration. The commit is the only Git write: no `git config` is written, and the working tree is clean afterwards.
- Output: on success, stdout is exactly these five lines (each ends with a newline), with `<dir>` as the caller typed it, and nothing else on stdout or stderr:
```
cd <dir>
kogen doctor
kogen intent shape slugify request.md
kogen intent approve slugify   # shows the card; run the approve command it prints
kogen intent build slugify
```

## The embedded starter project
Files are embedded in the binary (Go `embed`, including dot-files such as `.kogen/project.yaml` and `.gitignore`); no download.
- `lib/text.js`: CommonJS; exports `{ titleCase }` only. `titleCase(text)` upper-cases the first letter of each whitespace-separated word and lower-cases the rest. `slugify` does not exist yet.
- `test/text.test.js`: `node:test` tests of `titleCase`, runnable with `node --test`.
- `.kogen/project.yaml`: valid for the existing parser. `setup: []`, `fix: []`, `protect: []`; one check named `test` running `"$KOGEN_NODE" --test test/*.test.js`; acceptance `run` is the configuration guide's bundled-Cucumber command (`NODE_PATH="$KOGEN_CUCUMBER" "$KOGEN_NODE" "$KOGEN_CUCUMBER/@cucumber/cucumber/bin/cucumber.js" --strict --require 'features/steps/*.js' --format "message:$KOGEN_ACCEPTANCE_REPORT" "$KOGEN_ACCEPTANCE_FEATURES"`) with `steps_dir: 'features/steps'`; `models` are exactly the defaults `kogen init` writes (`project.DefaultModels()`; the file is the template/`RenderConfig` output form), so `kogen doctor` names the login to make (`kogen provider login chatgpt`).
- `.gitignore`: the line `.kogen/local/`. `features/steps/README.md`: one line saying step definitions for Kogen acceptance scenarios go there (it keeps the folder in Git).
- `request.md` (committed, so Build starts clean): asks for `slugify(text)` in `lib/text.js`, exported next to `titleCase`, with tests in `test/text.test.js`. It lists exactly these three examples, each on its own line in the form `- "<input>" → "<output>"` with both sides JSON string literals:
  - `"Hello, World!" → "hello-world"`
  - `"  Node.js   &   Kogen  " → "node-js-kogen"`
  - `"---Rock'n'Roll 101---" → "rock-n-roll-101"`
  and states exactly two rules: the result is lower-case; every run of non-alphanumeric characters (anything other than ASCII letters and digits) becomes a single hyphen, and hyphens are trimmed at both ends. The reference `s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '')` gives all three outputs.
- `README.md`: what the project is, the exact commands printed by `kogen starter`, and the known result: after shape → approve → build, the build lands one commit, the project's `test` check passes, and `slugify("Hello, World!")` returns `"hello-world"`.

## Decisions
- The `test` check is `"$KOGEN_NODE" --test test/*.test.js`, not the literal `--test test/`: on Node 24 (the toolchain in `.tool-versions`) `node --test test/` exits 1 with `Cannot find module '.../test'` even though the tests pass (probe 1). The shell-expanded glob runs the same files on every Node. (source: request)
- Examples use ASCII only, and "alphanumeric" is stated as ASCII letters and digits, so the two rules cannot disagree with the examples. (source: request)
- Target is checked before identity; either refusal changes nothing. (source: request)
- Failures are Kogen error lines with exit 3, like other environment refusals. (source: request)

## Source comparison
- `kogen starter <dir>`; create only into a missing/empty dir, else refuse with a clear message and change nothing: addressed (Interface; scenarios 4, 5).
- Embedded project, `git init`, one initial commit; no identity means refuse with the K21 fix text before writing: addressed (scenarios 1, 6, 7).
- Prints exactly the five next commands including the approve hint: addressed (Output; scenario 1).
- `lib/text.js` with `titleCase`, `test/text.test.js` under `node --test`, `.kogen/project.yaml` with bundled Cucumber, no install or network: addressed (embedded project; scenarios 2, 3).
- Checks use `"$KOGEN_NODE" --test test/`: CONFLICTING and adjusted to `"$KOGEN_NODE" --test test/*.test.js` (Decisions; probe 1: the literal command fails on Node 24). Scenario 3 runs the check as Build startup would via `kogen doctor`.
- `request.md` with three examples and two consistent rules: addressed (scenario 8, deterministic reference evaluation, plus three wrong variants each contradicted by an example).
- Models are the `kogen init` defaults, doctor reports the login: addressed (scenario 2 and a Go unit test comparing with `DefaultModels`).
- Known result in README: addressed (scenario 9 checks the text; the landed build itself needs a real model and is not run).
- Must stay: no existing command changes (existing tests unchanged apart from the help/parse tables); embedded, no network; the commit is the only Git write: addressed (scenario 1).
- Acceptance `doctor --quick` config ok and checks on the committed tree: addressed (scenarios 2, 3). Shape with a scripted fake provider reaches an approvable Intent: addressed (scenario 10, end-to-end of the configuration, not of model quality). All configured checks pass: normal verification. Host safety: temp dirs, synthetic credentials, only processes the scenarios start, no real provider.

## Tests
- `kogen starter` creates the project with one commit, clean tree, only the commit as Git write, and prints exactly the five commands: scenario 1 (scenario)
- doctor --quick reports config ok and the login to make; a full doctor runs the starter's own checks on the committed tree and passes: scenarios 2 and 3 (scenario)
- non-empty target refused and unchanged; empty existing directory accepted: scenarios 4 and 5 (scenario)
- missing Git identity refused with the K21 text before anything is written: scenarios 6 and 7 (scenario)
- request.md examples and rules agree, and the examples reject wrong variants: scenario 8 (scenario)
- README states the known result: scenario 9 (scenario)
- shape in the starter with a scripted provider reaches an approvable, approvable-by-hash Intent: scenario 10 (scenario)
- embedded `.kogen/project.yaml` parses and its models equal `DefaultModels`; embedded request.md examples agree with the reference slugify; `lib/text.js` exports only titleCase; creation/refusal logic (non-empty, file target, identity before write): Go unit tests in the new starter package (unit)
- `starter` parsing: one positional, no options, missing/extra argument exit 2, appears on the top help page: parse tests in cli/parse_test.go (unit)

## Feasibility
- Probe: on the repository's Node 24.21.0, `node --test test/` and `node --test test` exit 1 with `Cannot find module '.../test'` while `node --test test/*.test.js` and bare `node --test` exit 0. (probe 1: exit 0 overall, 0.4 s)
