# Pitch Lifecycle — Frontmatter, Directories, Ship Mechanics

The 6-directory lifecycle a pitch moves through, its YAML frontmatter schema (with a legacy dual-read
path), and the deterministic ship mechanics that move it between directories.

## 6 Directories (`codegen/pitches/`)

`draft/` → `ready/` → `shipped/` (happy path), plus `archive/` (superseded/rejected), `studio/`
(in-progress shaping scratch), `transcripts/` (session transcript captures, distinct from `codegen/logging/`
cycle logs).

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

Shipping a pitch is `File.rename!` from `ready/<slug>.md` to `shipped/<slug>.md` — deterministic, no
LLM involvement. Owned by `Mix.Tasks.Codegen.Loop` (single-cycle path) — NOT `OrchestrationLoop.run/1`,
a documented prior misattribution. The queue drain (`LoopQueueDrain`) performs the same rename after its
own ship-verification checks (see `context/loop-queue-drain.md`).

## Trigger Keywords

pitch lifecycle, pitch frontmatter, blocks_on, Blocks-on legacy, pitch-format-validator, draft ready shipped archive studio transcripts, Kahn topological sort, ordered_slugs, ship mv, File.rename!
