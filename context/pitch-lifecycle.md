# Pitch Lifecycle — Frontmatter, Directories, Ship Mechanics

The 7-directory lifecycle a pitch moves through, its YAML frontmatter schema (with a legacy dual-read
path), and the deterministic ship mechanics that move it between directories.

## 7 Directories (`codegen/pitches/`)

`draft/` → `ready/` → `building/` → `shipped/` (happy path), plus `archive/` (superseded/rejected),
`studio/` (in-progress shaping scratch), `transcripts/` (session transcript captures, distinct from
`codegen/logging/` cycle logs).

`building/` is a CLAIM directory, not a lifecycle stage a pitch author ever targets directly: `mix
codegen.loop` atomically renames `ready/<slug>.md` to `building/<slug>.md` at cycle start
(`Mix.Tasks.Codegen.Loop.claim_pitch!/2`, see `context/loop.md` § Possession by Rename) — possession by
same-filesystem `File.rename/2`, so a second builder racing the same slug gets ENOENT and refuses,
never silently double-building. A pitch is in `building/` only for the duration of its cycle:

- **Diff-failure** (the cycle's work did not land) → `restore_claim/2` moves it back to `ready/` —
  still dispatchable.
- **Verified landing** (HEAD advanced, ancestor-extended) → the retire is UNCONDITIONAL: the pitch
  moves to `shipped/` regardless of whether the working tree is clean at that instant (a dirty tree
  fires a loud, non-fatal exit code, `4`, rather than stranding the pitch — see `context/loop.md`).
- **Infra abort** or a **crash** mid-cycle → the pitch stays in `building/`, deliberately never
  auto-reconciled; `codegen-drain status` surfaces the count, the operator decides.

`building/` is gitignored, inheriting the existing `/codegen/` rule — machine-local queue state, never
committed.

## Frontmatter Schema + Legacy Dual-Read

Current pitches carry YAML frontmatter, notably `blocks_on: [slug, ...]` for dependency ordering
(consumed by `LoopQueue.parse_edges/2` — see `context/loop-queue-drain.md`). Legacy pitches (pre-
frontmatter) express the same dependency as prose: `Blocks-on: <slug>`. Both forms are read by the same
parser — frontmatter is preferred when present, prose is the fallback. New pitches should use
frontmatter; the prose form is a compatibility path, not the target format.

## Validation — Dual-Implemented (Bash + TS)

`pitch-format-validator.sh` (Claude) and `pitch-format-validator.ts` (Pi, TypeScript twin under
`harnesses/pi/pi-extensions/enforcement/src/hooks/`) both validate pitch frontmatter shape at write
time. Keep both in sync when the schema changes — no automated cross-language parity test enforces this
pair; a schema change to one without the other is a silent gap.

## Topological Ordering

`LoopQueue.ordered_slugs/1` (Kahn's algorithm) — topologically sorts `ready/` pitches by `blocks_on`
edges, raises on a dependency cycle. See `context/loop-queue-drain.md` for the consuming drain logic.

## Ship Mechanics

Shipping a pitch is `File.rename!` from `ready/<slug>.md` OR `building/<slug>.md` to
`shipped/<slug>.md` — deterministic, no LLM involvement. Owned by `Mix.Tasks.Codegen.Loop`
(single-cycle path) — NOT `OrchestrationLoop.run/1`, a documented prior misattribution. The retire is
UNCONDITIONAL on a verified landing: `LoopQueue.record_ship/4` + the rename run FIRST, before any
working-tree-cleanliness check — see `context/loop.md` § Possession by Rename. The queue drain
(`LoopQueueDrain`) performs the same rename after its own ship-verification checks, and also probes
`building/` as a ship source (see `context/loop-queue-drain.md`).

## Pitch Design — Checking for Hardcoded Readers

When a pitch adds a new lifecycle directory or queue-state transition, the solution sketch typically names a few writer functions (the paths that CREATE the directory or transition files into it). However, every reader that checks for the OLD directory must ALSO be updated — a hardcoded reader of the old path is a certain-blocking defect if missed. Example: a pitch that adds a `building/` claim directory names `maybe_ship_pitch/4` as the only `ready/`-matching site needing widening, but a grep of the codebase reveals two more readers already in flight: `LoopQueueDrain.ship/6` (raises `"in neither ready/ nor shipped/"` on the missing path) and `LoopQueue.write_frontmatter!/4` (attempts `File.read` on a not-yet-existing path). Both are CERTAIN-BLOCKING failures on every claimed pitch — both invisible from the pitch's own reference list.

**Pitch-design discipline**: Before writing the solution sketch, grep the literal old directory path across `lib/`, `test/`, and `shared/` to enumerate ALL hardcoded readers, not just the writer named in the problem statement. Document the full list in the sketch's Files-to-Touch or Integration Points sections. A reader you discover during implementation but didn't forecast is a plan defect — it should have been visible from the static proof (the grep). A missing reader causes a red-test failure at first run and adds rework cycles.

## Trigger Keywords

pitch lifecycle, pitch frontmatter, blocks_on, Blocks-on legacy, pitch-format-validator, draft ready building shipped archive studio transcripts, Kahn topological sort, ordered_slugs, ship mv, File.rename!, claim_pitch, possession, building directory, dirty_tree_exit_code, pitch design hardcoded readers, grep reader scope
