# GitHub Workflows Mix Generator

**Problem**: CI workflow YAML gets out of sync with the intended config when edited by hand.
**When**: Any time GitHub Actions workflow files need to be created or modified in a project using the `github_workflows` Mix library.
**See also**: none

## Solution

Edit `.github/github_workflows.ex`, then run `mix github_workflows.generate`. Never edit `.yml` files directly — they are generated artifacts.

```elixir
# ❌ Hand-editing .github/workflows/ci.yml directly
# ✅ Edit .github/github_workflows.ex, then regenerate

mix github_workflows.generate
```

The generator reads `.github/github_workflows.ex` and writes the corresponding `.yml` files. All logic (job names, steps, conditions, env vars) belongs in the `.ex` source; the YAML files are outputs, not inputs.

## Gotchas

If you commit only the `.yml` without regenerating from `.ex`, the next `mix github_workflows.generate` call will overwrite your hand-edits silently.
