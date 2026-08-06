defmodule CodegenTestHarness.RoleResolverTest do
  use ExUnit.Case, async: true

  alias CodegenTestHarness.RoleResolver

  # These tests used to hard-code "sonnet"/"opus"/"off" — literal copies of
  # templates/generator/config.yaml. One role retune reddened a dozen
  # assertions that had nothing to say about the retune, and the only fix was
  # to hand-edit the copies. The invariant worth asserting was never "the
  # developer runs on sonnet"; it is "the resolver returns WHAT THE FILE
  # SAYS". So read the file.
  #
  # Read independently of RoleResolver (same `yq`, own invocation) — asserting
  # the resolver against its own reader would be circular.
  @config_yaml Path.expand("../../../templates/generator/config.yaml", __DIR__)

  defp config!(key) do
    {out, 0} = System.cmd("yq", ["-r", key, @config_yaml])
    value = String.trim(out)
    refute value in ["", "null"], "config.yaml has no value at #{key}"
    value
  end

  @dev_role "developer-phoenix-backend"

  describe "resolve_role/2,3" do
    test "claude: reads model/effort from real config.yaml" do
      assert RoleResolver.resolve_role(@dev_role, "claude") ==
               {config!(".harness.#{@dev_role}.claude.model"),
                config!(".harness.#{@dev_role}.claude.effort")}
    end

    test "claude_code canonical harness name normalizes to claude" do
      # No config literal needed: the invariant IS that the two harness
      # spellings resolve identically.
      assert RoleResolver.resolve_role(@dev_role, "claude_code") ==
               RoleResolver.resolve_role(@dev_role, "claude")
    end

    test "unknown role raises" do
      assert_raise RuntimeError, fn ->
        RoleResolver.resolve_role("no-such-role-xyz", "claude")
      end
    end

    test "resolve_role/3 with empty opts behaves like resolve_role/2" do
      assert RoleResolver.resolve_role(@dev_role, "claude", []) ==
               RoleResolver.resolve_role(@dev_role, "claude")
    end
  end

  describe "resolve_escalation/2" do
    test "claude: reads escalate_model/escalate_effort from real config.yaml" do
      assert RoleResolver.resolve_escalation(@dev_role, "claude") ==
               {config!(".harness.#{@dev_role}.claude.escalate_model"),
                config!(".harness.#{@dev_role}.claude.escalate_effort")}
    end

    test "claude_code canonical harness name normalizes to claude" do
      assert RoleResolver.resolve_escalation(@dev_role, "claude_code") ==
               RoleResolver.resolve_escalation(@dev_role, "claude")
    end

    test "role with no escalation key configured -> :none, never raises" do
      assert RoleResolver.resolve_escalation("committer", "claude") == :none
    end

    test "unknown role -> :none, never raises (fail-safe, not fail-open)" do
      assert RoleResolver.resolve_escalation("no-such-role-xyz", "claude") == :none
    end
  end

  describe "resolve_harness/2" do
    test "no per-role override configured -> build_default_harness unchanged" do
      assert RoleResolver.resolve_harness("developer-phoenix-backend", "claude_code") ==
               "claude_code"
    end

    test "unknown role -> build_default_harness unchanged, never raises" do
      assert RoleResolver.resolve_harness("no-such-role-xyz", "claude_code") == "claude_code"
    end

    test "committer (no override) -> build_default_harness unchanged" do
      assert RoleResolver.resolve_harness("committer", "claude_code") == "claude_code"
    end
  end

  describe "resolve_fallback/3" do
    test "claude: reads rung 0 of the fallback chain from real config.yaml" do
      assert RoleResolver.resolve_fallback(@dev_role, "claude", 0) ==
               {config!(".harness.#{@dev_role}.claude.fallback[0].model"),
                config!(".harness.#{@dev_role}.claude.fallback[0].effort")}
    end

    test "claude_code canonical harness name normalizes to claude" do
      assert RoleResolver.resolve_fallback(@dev_role, "claude_code", 0) ==
               RoleResolver.resolve_fallback(@dev_role, "claude", 0)
    end

    test "rung past the end of a configured chain -> :none, never raises" do
      rungs = String.to_integer(config!(".harness.#{@dev_role}.claude.fallback | length"))
      assert RoleResolver.resolve_fallback(@dev_role, "claude", rungs) == :none
    end

    test "role with no fallback key configured -> :none, never raises" do
      assert RoleResolver.resolve_fallback("committer", "claude", 0) == :none
    end

    test "unknown role -> :none, never raises (fail-safe, not fail-open)" do
      assert RoleResolver.resolve_fallback("no-such-role-xyz", "claude", 0) == :none
    end
  end
end
