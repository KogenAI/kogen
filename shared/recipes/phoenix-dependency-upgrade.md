# Recipe: Routine Dependency Upgrade

## Problem

"Bump the deps" is a recurring, low-specificity task with no defined
procedure. Left improvised, a build either bumps everything blindly (risking
a broken gate with no isolation of which dep caused it) or stalls entirely
the moment one dependency's upgrade breaks something.

## Solution

A fixed four-step procedure: enumerate outdated deps, bump pins, run the
gate, and on a gate-breaking dependency — fail open on that single dep
(revert its pin, keep the rest bumped) rather than blocking the whole
upgrade or shipping a broken tree.

## Implementation

### 1. Enumerate outdated dependencies

```bash
mix hex.outdated
```

Read the full table — `Dependency | Current | Latest | Status`. Note which
deps are behind and by how much (patch/minor/major). A major version bump
carries higher breakage risk than a patch bump; treat them with more
caution but do not skip them silently.

### 2. Bump pins in `mix.exs`

Update version requirements for the deps identified in step 1:

```elixir
# mix.exs — before
{:phoenix_live_view, "~> 1.0.0"},

# mix.exs — after
{:phoenix_live_view, "~> 1.1.0"},
```

Then resolve and lock:

```bash
mix deps.get
mix deps.compile
```

`mix deps.get` updates `mix.lock` to match the new `mix.exs` pins. Never
hand-edit `mix.lock`.

### 3. Run the gate

```bash
make ci
```

(or `mix test` + `mix credo --strict` + `mix dialyzer` individually, if
`make ci` is unavailable in the target app). Read the FULL output — a
dependency bump can break compilation, tests, Credo (API/behaviour
changes), or Dialyzer (spec changes) independently of each other.

### 4a. Gate green — done

All deps bumped, gate passes. Commit `mix.exs` + `mix.lock` together (they
must travel as one atomic change — a mismatched pair leaves the lockfile
inconsistent with the declared requirement).

### 4b. Gate red — isolate and fail open on the single dep

Do not revert the whole bump. Identify which dependency broke the gate
(read the failure — compile error naming a module/function, a Credo rule
citing an updated API, a test failure in code touching the dep's
behavior). Then:

1. Revert **only that dependency's** pin in `mix.exs` back to its prior
   version.
2. Run `mix deps.get` again to re-lock just that dependency.
3. Re-run the gate — confirm it's green with the reverted dep + all other
   bumps still in place.
4. Report the un-bumpable dependency by name, its current vs. attempted
   version, and the specific gate failure it caused — so a human can
   decide whether to invest in the migration work separately.

```bash
# Example isolation — only trust_score was the offender
# mix.exs: revert {:trust_score, "~> 2.0"} back to "~> 1.4"
mix deps.get
make ci   # confirm green again with everything else bumped
```

Never leave the tree in a state where `make ci` is red. A partially-bumped,
fully-green tree is the correct deliverable; a fully-bumped, red tree is
not.

## Considerations

- **Bump in isolation when the risk is high** — for a major version bump on
  a heavily-used dependency (Ecto, Phoenix, LiveView), consider bumping
  that dep alone first, gating, then proceeding to the rest — rather than
  bumping everything in one pass and losing the ability to isolate which
  dep broke the gate.
- **`mix.exs` and `mix.lock` are a single unit** — never commit one without
  the other; a bumped `mix.exs` with a stale `mix.lock` silently keeps
  running the old version until someone runs `mix deps.get`.
- **Read Hex changelogs for major bumps** — `mix hex.outdated` shows
  version deltas only; a major bump (`1.x` → `2.x`) often has a documented
  migration guide worth reading before touching code.
- **Security advisories are not optional** — if `mix hex.outdated` or
  `mix deps.audit` (via the `mix_audit` dep, when present) flags a known
  vulnerability, that dependency's bump is not "routine" — treat it as
  higher priority than the rest of the batch.

## Related Recipes

- [Elixir Hex Library Release](elixir-hex-library-release.md) — the
  release-side counterpart when the app itself is a published Hex
  library.
