# Add kogen-ctx index and search

Slice 1 of 3 split from the approved `kogen-ctx-tool` (kept as a superseded reference in `drafts/`). Landing order:
**1. this Intent** → 2. `kogen-ctx-symbols-and-map` → 3. `kogen-ctx-mcp`. Shaped against develop fa48e817.
Citations into lib/ and scripts/ name functions; probe results are in `evidence/probe-2026-09-27.md` (P1–P9, carried
over unchanged; P10, rustfmt, added for this slice). ROADMAP row 14 (CTX-03, NAT-02 first slice), DIRECTION D5, D6
and rules 16, 17, 44, 46, 51.

This is the first Rust in the repository: one crate at `native/kogen-ctx/`, one binary `kogen-ctx` with two
subcommands, `index` and `search`, wired into `check`. `symbols`, `refs` and `map` are slice 2; `mcp` is slice 3.

**Why split.** The whole tool in one Build (Candidate XARfeVP5, 2036 lines) did not converge on the codex route: its
three proof tests were 14–39-line smoke checks, and the Final Review reopened the same findings twice (lesson 27 in
plan/research/build-failure-lessons-2026-09-25.md). This slice has four scenarios, and each one lists the exact
ExUnit test cases to write (`scenarios.yaml`, key `tests`).

## Launch

Precondition on the Build host, once, outside the Build (network; P2 S9: 19.6 s, 49 crates, 15 MB; 38 ms and no
network when already cached, S6):

```sh
mise exec rust@1.97.1 -- cargo fetch --locked --manifest-path .kogen/intents/approved/kogen-ctx-index-and-search/evidence/cargo/Cargo.toml
```

This fills the machine's shared cargo cache (`~/.cargo/registry`) with exactly the crates
`native/kogen-ctx/Cargo.lock` will pin. (On the Mac Studio it already ran for `kogen-ctx-tool`; the lock is
byte-identical, so it is a 0.1 s no-op there.) Inside the Build nothing fetches: the Developer's write boundary makes
`~/.cargo` read-only (P2 S4), and every cargo command that `check` or a test runs is `--locked --offline` (P8). Never
export `CARGO_HOME` before `mise exec` (P1: that re-points mise's global rust install).

```sh
mix kogen.build --route codex kogen-ctx-index-and-search
```

Every proof is offline, so the codex route applies (DIRECTION rule 51).

## Start from the Candidate

`evidence/candidate-XARfeVP5-22f254e8.diff` is the saved Candidate of `kogen-ctx-tool` against fa48e817. It applies
cleanly: `git apply .kogen/intents/approved/kogen-ctx-index-and-search/evidence/candidate-XARfeVP5-22f254e8.diff`.
Start there, then shape it to this Intent:

- **Keep as-is:** `.gitignore` (the `/native/kogen-ctx/target/` line), `mise.toml` (`rust = "1.97.1"`),
  `native/kogen-ctx/.cargo/config.toml`, `native/kogen-ctx/Cargo.toml`, `native/kogen-ctx/Cargo.lock` (byte-identical
  to `evidence/cargo/Cargo.lock`), `lib/kogen/ctx.ex`, `lib/mix/tasks/kogen.ctx.build.ex` except its
  `Mix.Task.run("app.start")` line (drop it: no other `kogen.*` task starts the app, and this one needs nothing
  started), and the `scripts/check/offline.py` hunks (`CARGO_STAGES`, `plan_phases/3`, `_stage_name/1`). These
  matched the approved design.
- **Delete:**
  - `native/kogen-ctx/src/tmp.rs`, a dead scratch file that no module declares.
  - `test/kogen/ctx_mcp_test.exs` and `test/kogen/ctx_tool_test.exs`. Neither is in `may_change_guarded_paths`, so
    `GuardedPaths` reports them as stray paths, and both would fail: the first runs the removed `mcp` subcommand, the
    second calls the old `CtxFixture.run(binary, root, home, args)`. Their replacements are `ctx_index_test.exs` and
    `ctx_search_test.exs`.
- **Rewrite** the two doc hunks (the Candidate's text is wrong in both place and content; see "Docs" below):
  - `README.md`: the Candidate appends a `###` section after the closing copyright line, and it advertises `symbols`,
    `refs`, `map` and `mcp` and `claude mcp add`. Replace it with a `##` section placed before `## Run the checks`
    that documents only `index` and `search`, with no mention of `symbols`, `refs`, `map`, `mcp` or
    `claude mcp add`, plus the prerequisites-line change.
  - `scripts/check/README.md`: the Candidate appends a paragraph after the ledger section at the end of the file.
    Remove it; the cargo stages go into step 1 of the check order instead (with the prerequisite and the
    never-fetch line).
- **Remove from `main.rs`:** the `symbols`, `refs`, `map` and `mcp` subcommands and everything only they use: tree-sitter
  parsing, `walk_elixir`, `collect_call`, `alias_names`, `resolve_mod` (a hard-coded table of fixture names), and the
  `symbols` and `refs` tables. Slice 2 rewrites these to its own spec, and none of the removed code carries over. The
  crate keeps its four dependencies (unused ones do not warn).
- **Fix** (the Final Review findings that belong to this slice):
  - F2: each search term is quoted with `"` **doubled**, not stripped (`guard"passes` → `"guard""passes"`).
  - `... <k> more` counts every hit beyond the limit. The Candidate fetched `limit + 1` rows, so it could never print
    more than `... 1 more`.
  - A run of more than 60 non-blank lines is cut into 60-line chunks.
  - Blob ids come from one `git hash-object --no-filters --stdin-paths` call per refresh, not one call per file, and
    that call gets only the files that pass the skip filters. `git ls-files --cached` still lists a deleted tracked
    file (B3's `lib/shop/format.ex`), and one missing path makes `hash-object --stdin-paths` fail as a whole.
  - A file that becomes skipped (symlink, over the size limit, not UTF-8) loses its rows and is reported as
    `removed`. The Candidate marks a file as seen before its size and UTF-8 checks, so its old rows stay.
  - Every failure to create, open or write the index (directory creation, open, schema creation, `BEGIN IMMEDIATE`,
    any insert or delete, `COMMIT`) is reported as `kogen-ctx: cannot write index at <path>: <reason>; set
    KOGEN_CTX_HOME to a writable directory`. The Candidate uses that wording only for directory creation and open.
  - With `KOGEN_CTX_HOME` and `HOME` both unset or empty, the tool fails with a clear error. The Candidate falls back
    to the relative path `Library/Caches/Kogen/ctx`, which is inside the checkout when run from the root.
  - The CLI (see "CLI surface"). The Candidate resolves the root before checking usage, so `kogen-ctx` with no
    arguments outside a checkout exits 1. It silently ignores `--root` with no value, accepts extra arguments to
    `index`, accepts `--limit 0` and negative limits, and its usage line lists
    `<index|search|symbols|refs|map|mcp>`.
  - F6: `nist_vectors` asserts all four FIPS 180-2 vectors (the Candidate's version omitted the 448-bit one).
  - The test fixture's `KOGEN_CTX_HOME` is a separate temp dir, never a directory inside the fixture checkout (the
    Candidate used `<fixture>/ctx-home`, which changes the fixture's `git status`).
  - F1: replace the smoke tests with the test cases listed in `scenarios.yaml`: rewrite `ctx_build_test.exs`, and
    write `ctx_index_test.exs` and `ctx_search_test.exs` new.

## Why (the code at fa48e817)

- There is no code index, no search over Intents and no Rust in the repository. Every session rediscovers structure
  with grep, glob and read. DIRECTION 1.8 calls context "huge", especially in big repos, and 1.7 rules out starting
  the BEAM for fast queries (a fresh Elixir start is ~185 ms, native is ~7 ms; research/hooks-rust-logging.md).
- D5 settles the shape: memory and Intents stay git-committed text; the index is derived, machine-local SQLite; a
  Rust `kogen-ctx` CLI serves it. D6: one Rust native edge grown in slices; Elixir stays the only owner of state. This
  index is not state: it is rebuilt from files on any machine and never committed.

## Outcome

### The crate: `native/kogen-ctx/`

- `Cargo.toml` is `evidence/cargo/Cargo.toml` (package `kogen-ctx` 0.1.0, edition 2024, `rust-version = "1.97"`)
  plus `[lints.rust] unsafe_code = "forbid"`. Its only dependencies are the four in that file: `rusqlite 0.40` with
  feature `bundled` (SQLite 3.53.2 with FTS5, P4), `tree-sitter 0.27`, `tree-sitter-elixir 0.3.5` and
  `serde_json 1`. `tree-sitter`, `tree-sitter-elixir` and `serde_json` are unused until slices 2 and 3, but they are
  pinned now so the lock and the launch fetch never change again. There are no dev-dependencies, no MCP SDK, no async
  runtime and no hashing crate.
- SHA-256 (used only for the project id) is hand-written in `src/sha256.rs`. Its unit test `nist_vectors` asserts
  the four FIPS 180-2 vectors:
  - `""` → `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`
  - `"abc"` → `ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad`
  - the 448-bit `abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq` →
    `248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1` (checked with `shasum -a 256` during
    shaping)
  - one million `a` → `cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0`
- `Cargo.lock` is a byte copy of `evidence/cargo/Cargo.lock` (SHA-256
  `2ef6860ee535431191646a3fd9fe9113d0c674b34b05d3cf2d8a306764fbf1a3`), the set the launch precondition fetched. Any
  dependency change would need a fetch the Build cannot do, and fails `check` offline.
- `.cargo/config.toml` sets `[build] target-dir = "../../_build/cargo"`, so cargo run from inside the crate also
  builds into `_build/cargo`, never `native/kogen-ctx/target/`. From the repo root with `--manifest-path`, cargo does
  not read that file (P6). So **every cargo command run from the repo root passes `--target-dir _build/cargo`**,
  including the Developer's own ad-hoc `cargo build`, `cargo test` and `cargo clippy`, not only `CARGO_STAGES` and
  `Kogen.Ctx`. (P3: `Kogen.Build.GuardedPaths` hashes ignored files, and of these paths only `_build` is volatile.)
- `native/kogen-ctx/target/` must not exist at the end of any turn. The guard does not catch it in this Build, because
  `native/kogen-ctx/**` is declared. So the root `.gitignore` gains the line `/native/kogen-ctx/target/`, which keeps a
  stray ~123 MB tree out of `git add -A` (`Kogen.Git.stage_and_verify_candidate/3`). The line is declared in
  `may_change_guarded_paths`, which makes it an ordinary guarded change (build-reliability scenario
  `declared-gitignore-edit`). Test D1 also asserts the directory does not exist. In later Builds a stray `target/` is
  an ignored-file change outside their guards, so `GuardedPaths` reworks it.
- The crate root has `#![deny(warnings)]`.

### Where the index lives and how it is keyed

- **The project root** is `git -C <dir> rev-parse --show-toplevel` of `--root <dir>` (default: the process cwd),
  canonicalized with `std::fs::canonicalize`, the same realpath `Kogen.ProjectScope.canonical/1` computes for an
  existing path.
- **Root errors:**
  - Not a Git checkout: `kogen-ctx: not a Git checkout: <dir>` on stderr, exit 1. `<dir>` is `std::fs::canonicalize`
    of the `--root` value or of the cwd, so on macOS it is `/private/var/…`, never `/var/…`.
  - A `--root` that does not exist or is not a directory: `kogen-ctx: not a directory: <value as given>`, exit 1.
  - Tests compare the not-a-checkout message against `Kogen.ProjectScope.canonical/1` of the directory they created,
    never against the spelling they passed. The controller's `TMPDIR` is `/var/folders/…`, while the Developer's
    per-Build temp dir is already canonical (`Kogen.Build.Workspace.temp_dir/1`), so only the canonical comparison
    passes in both.
- **The project id** is the lowercase hex SHA-256 of that canonical path, the same id as
  `Kogen.Build.Workspace.project_id/1`. A symlinked spelling or a subdirectory of the checkout gives the same id. A
  linked worktree (a Candidate) is its own checkout root, so it has its own id.
- **The index file** is `<ctx home>/<project id>/index.sqlite`:
  - `<ctx home>` is `KOGEN_CTX_HOME` when it is set and non-empty, else `$HOME/Library/Caches/Kogen/ctx` when `HOME`
    is set and non-empty. It is used as given, not canonicalized: the printed index path is that string joined with
    `<project id>/index.sqlite`.
  - With both unset or empty: `kogen-ctx: HOME is not set; set KOGEN_CTX_HOME to a writable directory` on stderr,
    exit 1, empty stdout, nothing written. There is no relative-path fallback.
    This check runs after usage is validated and BEFORE the root is resolved (no git runs without HOME).
  - Missing directories are created.
  - When the index cannot be created, opened or written there, at any step up to and including `COMMIT`:
    `kogen-ctx: cannot write index at <path>: <reason>; set KOGEN_CTX_HOME to a writable directory` on stderr,
    exit 1, empty stdout. `<path>` is the index file path; `<reason>` is the OS or SQLite error text. Inside a Build
    role's write boundary `$HOME` is read-only; handing roles a writable `KOGEN_CTX_HOME` is row 15's wiring.
  - Nothing is ever written inside the checkout.
- **It is derived:** when the file does not open as SQLite, `meta.schema_version` is not `1`, or `meta.root` is not
  the canonical root, the tool deletes it and rebuilds from files. Deleting it by hand is always safe. A later schema
  bumps `schema_version` and the old file is rebuilt, never migrated (slice 2 bumps it to `2`).
- **Schema 1:**
  - `meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)`, holding `schema_version` = `1` and `root`;
  - `files(path TEXT PRIMARY KEY, kind TEXT NOT NULL, blob TEXT NOT NULL)`;
  - `CREATE VIRTUAL TABLE chunks USING fts5(path UNINDEXED, kind UNINDEXED, start_line UNINDEXED, end_line UNINDEXED, body)`
    with the default `unicode61` tokenizer; `body` is the only indexed column.
- Writes happen in one `BEGIN IMMEDIATE` transaction with a 10-second busy timeout, so concurrent CLI calls share one
  index.

### What is indexed, and freshness by blob

- **Code:** `.ex` and `.exs` paths from `git ls-files -z --cached --others --exclude-standard` (tracked plus
  untracked-not-ignored; `deps/` and `_build/` are ignored), kind `code`. In this slice a code file is recorded in
  `files` (path, kind, blob) and nothing else; slice 2 adds its symbols and refs.
- **Intents:** every `.md`, `.yaml` and `.yml` regular file under `.kogen/intents/`, kind `intent`. They are walked
  on the file system, so the git-ignored `drafts/` and `approved/` are included. A path with a directory component
  ending in `-raw` (e.g. `evidence/codex-raw/`) is skipped.
- **Memory:** the same for `.kogen/memory/`, kind `memory`. These are project-memory's `<kind>/<id>.md` records,
  indexed as text and not validated; `mix kogen.memory.check` stays the validator. No `.kogen/memory/` → no memory
  rows.
- **Skipped:** symlinks (not followed), files over 1 MiB (code) or 512 KiB (docs), non-UTF-8 files, and listed paths
  that no longer exist (a deleted tracked file stays in `git ls-files --cached`).
- **Freshness:** the blob ids of the files that pass the skip filters, and only those, come from one
  `git hash-object --no-filters --stdin-paths` call over their current bytes (a skipped or missing path passed to it
  fails the whole call). A file whose blob id differs from `files.blob`, or that is new, is re-read and its rows
  replaced. A file in `files` that is no longer indexable, because it vanished or became skipped, has its rows
  removed and gets a `removed` line. Every other file is left untouched. An mtime change alone re-indexes nothing.
- **Every query command refreshes first** (the same step as `index`), so answers always match the working tree.
- **`kogen-ctx index` output**, in order:
  1. `index <index path>`
  2. `project <project id>`
  3. `rebuilt <yes|no>` (`yes` when the index was created or rebuilt in this call)
  4. one `reindexed <path>` line per re-read file, then one `removed <path>` line per removed file, each group sorted
     by path (byte order)
  5. last, `files <n> reindexed <k> removed <r>`, where `n` is the number of files now indexed.

### `search <query> [--limit N]` — Intents and memory

- **Chunks:** each doc is split into maximal runs of non-blank lines, and a run longer than 60 lines is cut into
  60-line pieces. `body` is the run's lines joined with `\n`; `start_line` and `end_line` are 1-based. Code is not in
  `chunks`.
- **The query** is the command's positional arguments joined by one space, so `search Mix lock` and
  `search "Mix lock"` are the same query. No positional argument is a usage error.
- **Terms:**
  - The query is split on whitespace, and a term with no alphanumeric character is dropped.
  - Each remaining term is quoted as an FTS5 string, with every `"` inside it doubled.
  - The terms are joined with spaces, so all must match.
  - No terms left → no output, exit 0.
  - Raw user text is never passed to `MATCH` (P4: an unquoted `ogen.Bu` is a syntax error).
- **Order:** `bm25(chunks)` ascending, then path, then start line. Default limit 20.
- **Output:** one line per hit, `<path>:<start>-<end> [<kind>] <snippet>`. The snippet is `body` with every
  whitespace run collapsed to one space, cut to its first 160 characters.
- With `--limit N` (a positive integer), output stops after N hit lines. When k more hits exist beyond N, the line
  `... <k> more` follows, where k counts all of them.

### CLI surface (this slice)

- The form is `kogen-ctx index [--root DIR]` or `kogen-ctx search <query>... [--limit N] [--root DIR]`.
- **Parsing:**
  - The first argument is the subcommand, `index` or `search`.
  - `--root DIR` (either subcommand) and `--limit N` (`search` only) may appear anywhere after it, each at most once,
    and each takes the next argument as its value.
  - Any other argument starting with `--` is an unknown option. For `search`, every remaining argument is a query
    word (`- :` is a word, not an option). `index` takes no other argument.
  - `N` is a positive decimal integer (`1`, `20`); `0`, `-1`, `+3`, `abc` and an empty string are bad.
- **Usage errors** (exit 2, empty stdout, stderr is the usage line
  `usage: kogen-ctx index [--root DIR] | kogen-ctx search <query>... [--limit N] [--root DIR]` and a newline):
  - no arguments, or an unknown subcommand;
  - `--root` or `--limit` with no value, or given twice;
  - `--limit` on `index`, or a bad `N`;
  - an unknown option;
  - any extra argument to `index`;
  - `search` with no query word.
- Usage is checked in full before the root is resolved, so a usage error exits 2 everywhere (also outside a Git
  checkout) and touches neither the root nor the index home.
- The usage line lists only this slice's subcommands; slices 2 and 3 extend it. Tests assert only that stderr starts
  with `usage: kogen-ctx`, so the extensions need no edit to this slice's tests (the same reason they never assert
  the literal `schema_version`).
- **Exit codes:**
  - 0 on success; no results is success.
  - 2 on a usage error (above).
  - 1 on a runtime error, with `kogen-ctx: <reason>` on stderr and empty stdout.
- Nothing but results goes to stdout. There is no BEAM and no daemon: each call is one process that reads SQLite
  directly and runs `git`.

### Building and locating it: `Kogen.Ctx` and `mix kogen.ctx.build` (Candidate hunks, kept)

- `Kogen.Ctx` (lib/kogen/ctx.ex, `use Boundary, deps: []`, with a moduledoc):
  - `fetch(root, opts \\ [])` runs `cargo fetch --locked --manifest-path <root>/native/kogen-ctx/Cargo.toml`, which
    needs the network only when a locked crate is missing from the cache. With `offline: true` it adds `--offline`,
    which only verifies that the cache holds every locked crate and fails instead of downloading.
  - `build(root)` runs `cargo build --release --locked --offline --manifest-path <root>/native/kogen-ctx/Cargo.toml
    --target-dir <root>/_build/cargo` and returns `{:ok, <root>/_build/cargo/release/kogen-ctx}`.
  - Both return `{:error, reason}` naming cargo's exit status and the tail of its output. When `cargo` is not on
    PATH they return `{:error, "cargo not found on PATH: install Rust 1.97.1 (mise.toml pins it)"}`.
- `mix kogen.ctx.build [--offline]` (lib/mix/tasks/kogen.ctx.build.ex, `use Boundary, deps: [Kogen.Ctx, Mix]`,
  control root = process cwd like the other tasks) runs `fetch/2` (with `offline: true` under `--offline`), then
  `build/1`, and prints only the binary's absolute path. Any other argument, or any error, is a `Mix.raise`. It
  does not call `Mix.Task.run("app.start")` (no other `kogen.*` task does, and nothing needs the app started).
  - Without the flag, it is the one-time step on a new machine (like `mix deps.get`).
  - With the flag, it is the network-free way to locate the binary, and the only form any test or `check` runs. So the
    offline gate never touches the network, even on a cold cache: it fails instead (P8).
- `mise.toml` gains `rust = "1.97.1"` in `[tools]` (Assumed 3). P7 probed test_helper's `mise which python3 2>&1`
  with the pin: the output was the single Python path every time, with no warning.

### `check` builds and tests the crate first (no new catalog target; Candidate hunks, kept)

`scripts/check/offline.py`:

- A module-level `CARGO_STAGES` holds exactly three commands, run from the checkout root:
  - `cargo fmt --check --manifest-path native/kogen-ctx/Cargo.toml`
  - `cargo build --release --locked --offline --manifest-path native/kogen-ctx/Cargo.toml --target-dir _build/cargo`
  - `cargo test --release --locked --offline --manifest-path native/kogen-ctx/Cargo.toml --target-dir _build/cargo`
- A new `plan_phases(root, guard, build_path)` returns the phase list `main()` passes to `run_ordered/4`. It has the
  same phases as today, including the `MIX_BUILD_PATH` split of credo and tests, with `CARGO_STAGES` added to the
  preparation phase next to format, compile and the clang guard. So the crate is built, and its Rust tests pass,
  before `TEST_COMPILE_STAGE` and before any ExUnit test runs. There is no cargo load beside timed tests, and the
  tests' own `Kogen.Ctx.build/1` is a no-op there (same profile and target dir).
- `_stage_name/1` names them `cargo-fmt`, `cargo-build` and `cargo-test` (for the `KOGEN_FAILURE_SIGNATURE` frame).
- `cargo fmt` needs the 1.97.1 toolchain's `rustfmt` component. P10: on the Mac Studio `mise exec rust@1.97.1 --
  rustfmt --version` and `cargo fmt --version` both print `rustfmt 1.9.0-stable (8bab26f4f6 2026-07-14)`, and
  `cargo --version` at the repo root is `cargo 1.97.1`. The MacBook was not probed for rustfmt.
- There is no Makefile or `priv/kogen/verification_targets.yaml` change: proof selectors must be ExUnit files anyway
  (`VerificationPlan` `valid_selector?/4`), and `check` already runs every ExUnit test. The test-reliability ledger
  binds rows by test name, no cataloged test is renamed or edited, and new tests need no row.

### Docs

Both doc hunks of the Candidate are rewritten, not kept ("Start from the Candidate").

- **README.md:**
  - The prerequisites paragraph under `## Get started` (README.md:28 at fa48e817) adds Rust 1.97.1 (pinned in
    `mise.toml`) and `mix kogen.ctx.build` once per machine.
  - A new `##` section "Context index (`kogen-ctx`)" sits immediately before `## Run the checks` (README.md:928 at
    fa48e817), never after the closing copyright line where the Candidate put it. It documents `index` and `search`
    only: the two command forms and their options, the output formats, the index path and key (`KOGEN_CTX_HOME`,
    the default under `$HOME`), freshness by blob and refresh-before-query, the derived rebuild, and that nothing is
    written into or committed from the checkout. It does not name `symbols`, `refs`, `map`, `mcp` or
    `claude mcp add`; slices 2 and 3 extend the section when they ship those.
  - README paths and `Module.fun/arity` references must pass `test/kogen/readme_guidance_test.exs`
    (`Kogen.Ctx.build/1`, `Kogen.Ctx.fetch/1` and `Kogen.Ctx.fetch/2` are exported).
- **scripts/check/README.md:**
  - The prerequisites sentence at the top (line 3) adds Rust 1.97.1 (pinned in `mise.toml`) with the locked crates
    already in the cargo cache (`mix kogen.ctx.build` once per machine), next to "dependencies already installed by
    `mix deps.get`".
  - Step 1 of the check order (lines 23-27, formatting, forced compilation and the native test guard) gains the three
    cargo stages: `cargo fmt --check`, then the offline locked release build and the offline locked release test of
    `native/kogen-ctx`, with output in `_build/cargo`, all before step 2's `TEST_COMPILE_STAGE`.
  - Next to "Never run `deps.get` during either measurement." (line 56), the same for crates: never fetch them
    during a measurement.
  - No paragraph is appended after the ledger section at the end of the file.

## Tests and fixtures

- **New files only** (plus the `.gitignore` line). Each test module uses `use ExUnit.Case, async: true` and mutates
  no VM-global cwd or environment: every binary run passes explicit `cd:` and `env:`.
- **`test/support/ctx_fixture.ex`** (`Kogen.Test.CtxFixture`, loaded with `Code.require_file` by the test files;
  slices 2 and 3 reuse it). It **holds every fixture file's bytes itself**:
  - The seven Elixir sources are `~S"""` heredocs. `lib/shop.ex` line 8 contains `opts \\ []`, which a plain heredoc
    would unescape; each file ends with one `\n`.
  - The Intent, memory, `.gitignore` and draft files below are literals.
  - The seven sources' SHA-256s (lowercase hex) are pinned in the module:
    - `lib/shop.ex` f935965dfac50cd7de8a8bc79f3f50882558f965897414e1f95dae870a9ad347
    - `lib/shop/cart.ex` 95c4253dc537f22bd5da4b240e578e8450e7dad888debb45dded3b3247c9dedc
    - `lib/shop/pricing.ex` 153b97be6681c8b5b7e5772c38fd12f3adb0ea28709925acc6567e07f473c602
    - `lib/shop/tax.ex` ccd8a1bdbbb04ba37ac2fe94e5379909f33a81f8e594b08e396729d264186fba
    - `lib/shop/inventory.ex` e85ff40c86d85b5a856dd89b985ba78863eb75d626c1abda6b7847f112653338
    - `lib/shop/format.ex` 969cbe862d666d2f15330ec6f964e829fedbaea60de800e5b3573f2435612b7a
    - `test/shop_test.exs` 59f23a5513964b133c5496d1c8953d6e1d8790ade8caf75f0d65c6ed83793200
  - The Candidate's module already has these bytes and hashes; keep them.
- **Its public functions** (tests call only these):
  - `create!()` → `{root, home}`: a fresh fixture repository in a unique temp dir, and a **separate** fresh empty
    temp dir `home` for `KOGEN_CTX_HOME`, outside `root`.
  - `binary()` → the binary's path, cached in `:persistent_term` after the first successful `Kogen.Ctx.build/1` on
    the checkout root; it raises with the build error otherwise. Concurrent first callers are serialized by cargo's
    build-directory lock, and under `check` the `cargo-build` stage has already built it.
  - `run(root_or_cwd, home, args, opts \\ [])` → `{stdout, stderr, status}`. It runs
    `System.cmd("/bin/sh", ["-c", ~S(err="$1"; shift; exec "$0" "$@" 2>"$err"), binary(), stderr_file | args], cd:
    root_or_cwd, env: env)`, reads and deletes `stderr_file`, and returns the triple. `env` is
    `PATH=/usr/bin:/bin` (the no-BEAM proof) plus `KOGEN_CTX_HOME=home`, merged with `opts[:env]`; a `nil` value
    unsets a name, as `System.cmd/3` does.
  - `sources()` and `hashes()`.
- **No test or support file reads anything under the checkout's `.kogen/`** (not this package's
  `evidence/fixture/`, not any Intent). The fixture's own `.kogen/` in its temp dir is written from the embedded
  literals. The package moves to `complete/` after the Build, and the owner-run cold-offline copy excludes
  `.kogen/intents` (`SOURCE_EXCLUDED_PATHS` in `scripts/check/offline.py`), so such a read would pass in this
  Candidate and fail every later `check`.
- With `PATH=/usr/bin:/bin`, every `git` call goes through Apple's `/usr/bin/git` launcher (~8 ms per call, P9).
  Keep runs per test to what the case needs; queries refresh anyway.
- The 0500 `KOGEN_CTX_HOME` case restores mode 0700 in an `on_exit` callback so temp-dir cleanup can delete it; the
  read-only index case (A6) restores its directory to 0700 and its file to 0600 the same way.
- Test files: `test/kogen/ctx_index_test.exs` (scenarios A and B), `test/kogen/ctx_search_test.exs` (C),
  `test/kogen/ctx_build_test.exs` (D).
- **The fixture repository.** `git init`, a local `core.excludesFile` pointing at an empty file inside its `.git` (as
  isolate-test-git-config does), then one commit of the tracked files. It contains:
  - The seven Elixir files, byte-identical to `evidence/fixture/`: `lib/shop.ex`, `lib/shop/cart.ex`,
    `lib/shop/pricing.ex`, `lib/shop/tax.ex`, `lib/shop/inventory.ex`, `lib/shop/format.ex`, `test/shop_test.exs`.
  - `.gitignore`: `/_build/`, `/deps/`, `.kogen/intents/drafts/`, `.kogen/intents/approved/`, `*-raw/`.
  - `.kogen/intents/complete/stray-rework/INTENT.md`, 9 lines: `# Rework stray paths`, blank, `## Why`, blank,
    `A stray Mix lock directory stopped the Build.`, blank, `## Outcome`, blank,
    `The Developer deletes each stray path and the guard passes.`
  - `.kogen/intents/complete/stray-rework/scenarios.yaml`, 3 lines: `- id: stray-file-reworked`,
    `  given: A fixture with a stray file.`, `  then: The guard reworks the stray file.`
  - `.kogen/memory/lesson/lesson-stray-rework.md`, 5 lines: `---`, `id: "lesson-stray-rework"`, `kind: "lesson"`,
    `claim: "stray-rework published after 2 stopped Builds: stray Mix lock directories"`, `---`.
  - Untracked, not ignored, and never indexed:
    - the symlink `lib/shop/link.ex` → `tax.ex`;
    - `lib/shop/latin1.ex`, whose bytes are `# caf`, 0xE9, `\n` (not UTF-8);
    - `.kogen/intents/complete/stray-rework/evidence/big.md`, 102,400 lines of `stray` (614,400 bytes, over the
      512 KiB doc limit).
  - Untracked and ignored:
    - `.kogen/intents/drafts/cart-discounts/INTENT.md`, 3 lines: `# Add cart discounts`, blank,
      `Discounts apply before tax in Shop.Pricing.`;
    - `.kogen/intents/complete/stray-rework/evidence/codex-raw/stream.md` (`stray stray stray`);
    - `deps/dep/lib/dep.ex` (`defmodule Dep do def x, do: 1 end`).
- **Expected outputs.** The outputs in scenarios.yaml come from the `evidence/fixture/` files; the bm25 order is from
  `evidence/fts5-bm25-probe.txt`. All of them are carried over unchanged from `kogen-ctx-tool`, which Opus
  hand-verified. The only new expected outputs are:
  - the long-run chunk case (C9), derived from the 60-line rule;
  - the query-refresh case (B4), derived from the freshness rule;
  - the lock hash (D4, `shasum -a 256` of `evidence/cargo/Cargo.lock`);
  - the 448-bit vector;
  - the usage-error cases (A5 (v)-(viii)), the no-HOME and read-only-index cases (A6), the became-skipped case (B5)
    and `--limit 1` (C3), derived from "CLI surface", "Where the index lives" and the freshness rule.

## Non-goals

- `symbols`, `refs`, `map` and tree-sitter extraction (slice 2); `mcp` (slice 3).
- Role briefings, ranked locators per role, budgets, prompt wiring, `brief` and the benchmark (row 15); `record-read`
  and the working set (row 16); a `memory` subcommand or memory validation.
- A per-Build overlay on a shared base index, `mix xref` or compiler enrichment, embeddings, a warm daemon, other
  languages (later CTX-03 slices, 16b program-database).
- The `kogen` binary name, `kogen hook`, `status`, `log`, the launcher, `make install` and release packaging
  (rust-native-edge). Studio or cross-repo indexes (rule 39).
- Changing the Build: no Workspace seeding of `_build/cargo`, no Developer-prompt change, no catalog target.
