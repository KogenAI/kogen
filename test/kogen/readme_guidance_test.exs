defmodule Kogen.ReadmeGuidanceTest do
  use ExUnit.Case, async: true

  @readme File.read!(Path.join(File.cwd!(), "README.md"))
  @shaping_prompt File.read!(Path.join(File.cwd!(), "priv/kogen/prompts/shaping.md"))

  test "README documents the self-hosting expand-and-contract section" do
    assert @readme =~ "## Self-hosting changes: expand and contract"

    compact = Regex.replace(~r/\s+/, @readme, " ")

    for text <- [
          "Kogen builds itself",
          "main's controller",
          "the code loaded when `mix kogen.build` started",
          "Removals therefore follow expand and contract",
          "zero-downtime database migration",
          "one Intent adds the new path, switches the new controller to it",
          "the next Intent, built under the new controller, removes the old path"
        ] do
      assert compact =~ text
    end
  end

  test "README lists every self-hosting input with its source location" do
    compact = Regex.replace(~r/\s+/, @readme, " ")

    for text <- [
          "the catalog and its change rules: `priv/kogen/verification_targets.yaml`, `lib/kogen/build/verification_plan.ex` (`VerificationPlan.load/1`), `lib/kogen/build/catalog_change.ex` (`CatalogChange.check/4`)",
          "the Make target definitions: `Makefile`, run by `lib/kogen/build/verification_runner.ex` (`VerificationRunner.run_target/4`)",
          "the admission catalog's integrity fields: `verification_surface`, `focused_runner` and `base_cache` in `priv/kogen/verification_targets.yaml`, consumed by `lib/kogen/build/base_workspace.ex` and `lib/kogen/build/ledger.ex`",
          "the files and registrations `VerificationPolicy.preflight` requires: `lib/kogen/verification_policy.ex` (`.codex/hooks/verification_policy.py` and the PreToolUse registration in `.codex/hooks.json`)",
          "the Stop scripts and registrations (bootstrap only): `.codex/hooks/check.sh`, `.codex/hooks/stop_runner.py`, `.codex/hooks.json`, `priv/kogen/claude_code/settings.json`",
          "the guarded-path check: `lib/kogen/build/guarded_paths.ex` (`GuardedPaths.check/2`)",
          "the approved package: `.kogen/intents/approved/<slug>/`, read by `lib/kogen/build.ex` and `lib/kogen/build/contract.ex`"
        ] do
      assert compact =~ text
    end

    assert compact =~ "priv/kogen/prompts/developer.md"
    assert compact =~ "priv/kogen/prompts/reviewer.md"
    assert compact =~ "priv/kogen/test-reliability.yaml"
  end

  test "README gives the worked example for the current self-hosting Intent" do
    compact = Regex.replace(~r/\s+/, @readme, " ")

    assert compact =~ "fortify-paid-verification"
    assert compact =~ "the next (follow-up verification) Intent"
    assert compact =~ "removes them"
    assert compact =~ "`live-native` split is done next"
    assert compact =~ "declared `catalog_changes.add`"
  end

  test "shared Shaping prompt does not carry the Kogen-specific self-hosting section" do
    refute @shaping_prompt =~ "## Self-hosting changes: expand and contract"
    refute @shaping_prompt =~ "Self-hosting changes: expand and contract"
    refute @shaping_prompt =~ "expand and contract"
  end
end
