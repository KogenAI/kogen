# ExAST for Structural Search and Refactor

**Problem**: A refactor or audit needs to match Elixir code by structure (a function head, a struct field, a call inside a specific block) — not by regex. Hand-edits across many files are slow and error-prone; regexes miss multi-line forms and break on whitespace.
**When**: ≥ 5 callsites to update, an audit rule that grep can't express precisely (e.g. "Repo.transaction inside def handle_event but never IO.inspect inside the same function"), or a fixture migration after a schema rename.
**See also**: `elixir-type-duplication.md` (grep-based detection), `tidewave-mcp-verification.md` (verify a library before using it)

## What it is

[ExAST](https://github.com/dannote/ex_ast) (`ex_ast` on Hex, MIT, latest 0.8.0 at time of writing) parses Elixir source to AST, matches against patterns written as plain Elixir (with `_` as wildcard and bare names as captures), and rewrites via `Sourceror` so comments and source positions survive. v0.6 added CSS-like selectors with parent/ancestor/has-descendant predicates and a `--not-*` family of flags.

## How to run it — pick by use case

ExAST does **not** ship as an escript or archive, so the Mix tasks (`mix ex_ast.search`, `mix ex_ast.replace`) only work when `ex_ast` is loaded into the current Mix environment. The library API (`ExAST.search/2`, `ExAST.replace/3`) works from any `Mix.install` script. Three viable setups:

### A. One-off refactor inside a user app — `Mix.install` script (default)

Use this for any refactor against a user app where we don't want to pollute the user's `mix.exs`. Drop a script in the project root, run, delete:

```elixir
# refactor.exs (gitignored or deleted after use)
Mix.install([{:ex_ast, "~> 0.8"}])

# Always start with a search to confirm matches
ExAST.search("Repo.get!(_, _)", paths: ["lib/", "test/"])
|> Enum.each(&IO.puts("#{&1.file}:#{&1.line}"))

# Then enable the replace once the match list looks right
# ExAST.replace("Repo.get!(mod, id)",
#               "Repo.get!(mod, id) || raise NotFoundError",
#               paths: ["lib/"])
```

Run with `elixir refactor.exs`. First run takes ~10-30s (Hex fetch + compile, cached in `~/.cache/mix/installs/`); subsequent runs with the same dep list are ~1-2s. **Trade-off**: no CLI flags — you write `ExAST.search/2` calls instead of `mix ex_ast.search ... --inside ...`. For one-off work that's fine; review the match list by reading the script's output before uncommenting the `replace`.

### B. Everyday CLI access — sidecar project (recommended for repeat use)

If you reach for ExAST more than once a month, set up a one-time sidecar project so `mix ex_ast.search` works against any path without touching the target's deps:

```bash
mkdir -p ~/tools/ex_ast_runner && cd ~/tools/ex_ast_runner
mix new .
# Add {:ex_ast, "~> 0.8"} to deps in mix.exs, then:
mix deps.get && mix compile
```

Then from anywhere:

```bash
cd ~/tools/ex_ast_runner
mix ex_ast.search 'IO.inspect(_)' /path/to/my_app/lib/
mix ex_ast.replace --dry-run 'dbg(expr)' 'expr' /path/to/some/user-app/lib/
```

The CLI accepts arbitrary paths — the target project doesn't need ex_ast at all.

### C. Add to the project's own deps — only when the team will use it repeatedly

```elixir
# mix.exs — only for projects where >1 developer will run audits/refactors locally
def deps do
  [{:ex_ast, "~> 0.8", only: [:dev, :test], runtime: false}]
end
```

Don't do this for user apps we generate. The 0.x API is still moving — pin tight and never depend on it from runtime code or release builds.

## CLI cheat sheet (Setup B)

```bash
# search
mix ex_ast.search 'IO.inspect(_)' lib/                          # find all calls
mix ex_ast.search '%User{role: "admin"}' lib/ test/             # struct by field
mix ex_ast.search --count 'dbg(_)'                              # count only
mix ex_ast.search --inside 'defp _ do _ end' 'Repo.get!(_, _)'  # context filter
mix ex_ast.search --not-inside 'test _ do _ end' 'IO.inspect(_)'

# replace
mix ex_ast.replace 'dbg(expr)' 'expr'                           # capture + reuse
mix ex_ast.replace 'IO.inspect(expr, _)' 'expr'                 # drop the opts
mix ex_ast.replace --dry-run 'use Mix.Config' 'import Config'   # preview before write
mix ex_ast.replace 'Repo.get!(mod, id)' \
                   'Repo.get!(mod, id) || raise NotFoundError'
```

Pattern conventions (from the README):

- `_` matches any single AST node (wildcard).
- A bare name like `expr` or `mod` is a **capture** — the same name in the replacement substitutes the captured node.
- Structs match partially: `%Step{id: "subject"}` matches that struct with that field, regardless of other fields.
- Pipes are normalized — `a |> f(b)` and `f(a, b)` match the same pattern.
- After `replace`, run `mix format` for consistent style. Comments and positions are preserved.

## Programmatic — selector chains (works in Setup A too)

For audits or scripts that want predicate composition:

```elixir
import ExAST.Selector

# Every handle_event/3 that touches the Repo and does NOT log via IO.inspect
selector =
  pattern("defmodule _ do ... end")
  |> descendant("def handle_event(_, _, _) do ... end")
  |> where(has_descendant("Repo.transaction(_)"))
  |> where(not(has_descendant("IO.inspect(_)")))

ExAST.search("lib/", selector)
```

Relationship functions: `child/2`, `descendant/2`, `parent/1,2`, `ancestor/1,2`, `has_child/1,2`, `has_descendant/1,2`, `has/1,2`. CLI mirrors these with `--parent`, `--ancestor`, `--inside`/`--contains`, `--has`, plus `--not-*` negations and `--follows` / `--immediately-follows` / `--nth` for sibling position.

## Where this fits in the build platform

1. **User-app codebase migrations**. When a Phoenix seed pattern changes, run `mix ex_ast.replace --dry-run` against the seed bundle to see exactly which files change before committing — much safer than `mix.format` + sed.
2. **Structural audits as lint**. Encode invariants we currently grep for (e.g. "every Oban worker `perform/1` ends with explicit `:ok`", per `oban-worker-return-contract.md`) as a selector script in `scripts/audit_*.exs` and run it from `make ci`. The match list is precise; greps over-match.
3. **Fixture rewrites after schema renames**. When a context renames a field, `mix ex_ast.replace '%MySchema{old_field: v}' '%MySchema{new_field: v}'` updates every test fixture in one pass. Always run with `--dry-run` first and commit the diff in a single mechanical commit so review is cheap.
4. **Cleanup before commit**. Catch stray `dbg/1`, `IO.inspect/1,2`, and forgotten `Logger.debug` lines without disabling them globally — `mix ex_ast.search --not-inside 'test _ do _ end' 'IO.inspect(_)'`.

## Gotchas

- **Library is pre-1.0** (0.8.0 at time of writing). The selector API is still being shaped — don't build long-lived code on top of `ExAST.Selector`. Use it for one-shot refactors and ad-hoc audits, not as a runtime dependency.
- **Always run `--dry-run` first** for `replace`. The matcher's "structs match partially" rule is convenient but can match more than you expect — review the dry-run output before letting it write.
- **Run `mix format` after every replace.** The replacement is rendered by `Macro.to_string/1`, which produces correct but not-yet-formatted code.
- **Heredocs and sigils**: structural matching on string-heavy code (HEEx, large heredocs) is weaker than on plain Elixir — the AST is just a string node. For HEEx changes, prefer Phoenix's component migration patterns (`phoenix-component-migration.md`) over ExAST.
- **Don't run it through the orchestrator's developer subagents as a substitute for understanding the change.** It's a power tool for mechanical edits the developer has already specified — not a planning aid.
