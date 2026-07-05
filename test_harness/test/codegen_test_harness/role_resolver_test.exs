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

      assert model == "openai-codex/gpt-5.4"
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
end
