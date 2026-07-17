# Downstream Consumer Docs — `shared/apps/`

Templates + committed rendered outputs for AGENTS.md/CLAUDE.md that downstream consumer repos
(Phoenix, static-site) get via `codegen-scaffold`. Distinct from codegen's OWN root `AGENTS.md`/
`CLAUDE.md` (hand-authored regular files, no template, see `context/repo-structure.md`).

## Sources → Outputs (2 `.j2` → 4 committed `.md`)

| `.j2` source                       | Renders to (per-harness param)                                                              |
| ---------------------------------- | ------------------------------------------------------------------------------------------- |
| `shared/apps/AGENTS-phoenix.md.j2` | `shared/apps/AGENTS-phoenix.md` (pi param) + `shared/apps/CLAUDE-phoenix.md` (claude param) |
| `shared/apps/AGENTS-static.md.j2`  | `shared/apps/AGENTS-static.md` (pi param) + `shared/apps/CLAUDE-static.md` (claude param)   |

All 4 rendered `.md` files are COMMITTED/tracked — not gitignored. Editing content means editing the
`.j2` source and running `make install` (or the `rule-render-freshness` gate's own render), then
committing the regenerated `.md` files alongside the `.j2` change.

## `rule-render-freshness` Gate — Checks Exactly These 4, Nothing Else

Component of `make test`. Renders both `.j2` sources fresh (both `pi` and `claude` params) into a tmp
dir, runs the SAME prettier pass the real render uses, diffs against committed content. A STALE verdict
names which of the 4 files drifted. This gate does NOT check `shared/apps/PROJECT_CONTEXT-*-template.md`
or `shared/apps/context-*.md` — those are separate scaffold assets copied as-is by `codegen-scaffold`,
not rendered by `process_template.py`, and are outside this gate's scope.

## Downstream Repos' `CLAUDE.md`/`AGENTS.md` Are Committed Symlinks

In a scaffolded downstream repo, `CLAUDE.md` (mode 120000) points at the harness-specific rendered
file; `AGENTS.md` likewise. Both symlink targets are the committed `shared/apps/*.md` files above —
copied into the downstream repo's tree by `codegen-scaffold`, not re-rendered per-app.

## Trigger Keywords

shared/apps, AGENTS-phoenix.md.j2, AGENTS-static.md.j2, downstream AGENTS.md, downstream CLAUDE.md, rule-render-freshness, committed symlink, scaffold docs render
