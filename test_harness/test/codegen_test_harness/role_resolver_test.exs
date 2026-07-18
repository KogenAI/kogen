defmodule CodegenTestHarness.RoleResolverTest do
  use ExUnit.Case, async: true

  alias CodegenTestHarness.RoleResolver

  describe "resolve_role/2,3" do
    test "claude: reads model/effort from real config.yaml" do
      {model, effort} = RoleResolver.resolve_role("developer-phoenix-backend", "claude")

      assert model == "sonnet"
      assert effort == "medium"
    end

    test "pi: reads pi-specific model/effort" do
      {model, effort} = RoleResolver.resolve_role("developer-phoenix-backend", "pi")

      assert model == "openai-codex/gpt-5.6-terra"
      assert effort == "medium"
    end

    test "claude_code canonical harness name normalizes to claude" do
      {model, effort} = RoleResolver.resolve_role("developer-phoenix-backend", "claude_code")

      assert model == "sonnet"
      assert effort == "medium"
    end

    test "unknown role raises" do
      assert_raise RuntimeError, fn ->
        RoleResolver.resolve_role("no-such-role-xyz", "claude")
      end
    end

    test "resolve_role/3 with empty opts behaves like resolve_role/2" do
      {model, effort} = RoleResolver.resolve_role("developer-phoenix-backend", "claude", [])

      assert model == "sonnet"
      assert effort == "medium"
    end
  end

  describe "resolve_escalation/2" do
    test "claude: reads escalate_model/escalate_effort from real config.yaml" do
      assert RoleResolver.resolve_escalation("developer-phoenix-backend", "claude") ==
               {"opus", "high"}
    end

    test "pi: reads pi-specific escalation tier" do
      assert RoleResolver.resolve_escalation("developer-phoenix-backend", "pi") ==
               {"openai-codex/gpt-5.6-sol", "high"}
    end

    test "claude_code canonical harness name normalizes to claude" do
      assert RoleResolver.resolve_escalation("developer-phoenix-backend", "claude_code") ==
               {"opus", "high"}
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

      assert RoleResolver.resolve_harness("developer-phoenix-backend", "pi") == "pi"
    end

    test "unknown role -> build_default_harness unchanged, never raises" do
      assert RoleResolver.resolve_harness("no-such-role-xyz", "claude_code") == "claude_code"
    end

    test "committer (no override) -> build_default_harness unchanged" do
      assert RoleResolver.resolve_harness("committer", "pi") == "pi"
    end
  end

  describe "resolve_fallback/3" do
    test "claude: reads rung 0 of the fallback chain from real config.yaml" do
      assert RoleResolver.resolve_fallback("developer-phoenix-backend", "claude", 0) ==
               {"opus", "medium"}
    end

    test "pi: reads pi-specific rung 0" do
      assert RoleResolver.resolve_fallback("developer-phoenix-backend", "pi", 0) ==
               {"openai-codex/gpt-5.6-sol", "medium"}
    end

    test "claude_code canonical harness name normalizes to claude" do
      assert RoleResolver.resolve_fallback("developer-phoenix-backend", "claude_code", 0) ==
               {"opus", "medium"}
    end

    test "rung past the end of a configured chain -> :none, never raises" do
      assert RoleResolver.resolve_fallback("developer-phoenix-backend", "claude", 1) == :none
    end

    test "role with no fallback key configured -> :none, never raises" do
      assert RoleResolver.resolve_fallback("committer", "claude", 0) == :none
    end

    test "unknown role -> :none, never raises (fail-safe, not fail-open)" do
      assert RoleResolver.resolve_fallback("no-such-role-xyz", "claude", 0) == :none
    end
  end
end
