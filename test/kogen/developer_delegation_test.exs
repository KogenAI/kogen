defmodule Kogen.DeveloperDelegationTest do
  use ExUnit.Case, async: true

  # Resolved from this file, never the shared VM's mutable working directory.
  @root Path.expand("../..", __DIR__)

  alias Kogen.ExecutionPolicy
  alias Kogen.Harness.Claude
  alias Kogen.Intent

  test "the default optimum Developer is Opus Medium with native Sonnet 5.5 scouts and workers" do
    config = selected_config!()
    policy = ExecutionPolicy.render(config, "developer", @root)

    assert config.route == "optimum"
    assert Intent.role_harness(config, :developer) == "claude"
    assert config.developer == %{model: "claude-opus-5-5", effort: "medium"}
    assert Intent.role_harness(config, :reviewer) == "codex"
    assert config.reviewer == %{model: "gpt-6.1-sol", effort: "high"}
    assert config.helpers.scout == %{model: "claude-sonnet-5-5", effort: "low"}
    assert config.helpers.worker == %{model: "claude-sonnet-5-5", effort: "medium"}

    assert policy =~ "Configured root (developer): `claude-opus-5-5` at `medium`"
    assert policy =~ "The configured scout is `claude-sonnet-5-5` at `low`"
    assert policy =~ "worker is `claude-sonnet-5-5` at `medium`"
    refute policy =~ "claude-sonnet-5`"

    # The native agents the Developer launch carries are the frozen helpers.
    agents = Claude.agents("developer", config.helpers)
    assert agents["kogen-worker"]["model"] == "claude-sonnet-5-5"
    assert agents["kogen-worker"]["effort"] == "medium"
    assert agents["kogen-scout"]["model"] == "claude-sonnet-5-5"
    assert agents["kogen-scout"]["effort"] == "low"
    refute Map.has_key?(agents, "kogen-expert")
  end

  test "optimum Codex helpers use Luna Max workers while existing Codex routes keep theirs" do
    optimum = selected_config!()
    reviewer = Intent.role_config(optimum, :reviewer)
    assert reviewer.harness == "codex"
    assert reviewer.helpers.worker == %{model: "gpt-6-luna", effort: "max"}

    assert ExecutionPolicy.render(optimum, "reviewer", @root) =~
             "`gpt-6-luna` at `max`; native kind `worker`"

    for route <- ~w(codex codex-dominant-adversarial-claude claude-dominant-adversarial-codex) do
      config = selected_config!(route)
      assert config.native_helpers["codex"].worker == %{model: "gpt-6-luna", effort: "high"}
    end

    codex_dominant = selected_config!("codex-dominant-adversarial-claude")
    policy = ExecutionPolicy.render(codex_dominant, "developer", @root)
    assert policy =~ "Configured root (developer): `gpt-6.1-sol` at `high`"
    assert policy =~ "`gpt-6-luna` at `low`; native kind `explorer`"
    assert policy =~ "`gpt-6-luna` at `high`; native kind `worker`"
    refute policy =~ "`gpt-6-luna` at `max`"
  end

  test "Developer policy starts useful independent slices together and keeps coupled work serial" do
    for route <- [nil, "codex-dominant-adversarial-claude"] do
      policy = ExecutionPolicy.render(selected_config!(route), "developer", @root) |> flat()

      assert policy =~ "When at least two useful independent slices are available"
      assert policy =~ "explicit disjoint ownership"
      assert policy =~ "coupled work serial"
      assert policy =~ "name the concrete"
      assert policy =~ "Helpers must not fan out"
      assert policy =~ "failure to the root"
      assert policy =~ "review all returned work"
      assert policy =~ "controller verification"
      assert policy =~ "gate, Make target or Stop script"
      assert policy =~ "modify outside their assigned ownership"
    end

    assert ExecutionPolicy.render(
             selected_config!("codex-dominant-adversarial-claude"),
             "developer",
             @root
           ) =~
             "start bounded Codex-native scout and worker tasks concurrently"
  end

  test "every helper packet carries task, deliverable, focused checks, time budget and blocker reporting" do
    policy = ExecutionPolicy.render(selected_config!(), "developer", @root)
    flat = flat(policy)

    for phrase <- [
          "names its task, deliverable, the focused test commands with their expected results, a time budget and how to report a blocker",
          "actually runs its assigned focused check",
          "a command that never started or a syntax-only check is not completion",
          "partial progress is reported as partial",
          "without launching extra reviewer helpers",
          "check the combined behavior"
        ],
        do: assert(flat =~ phrase, "missing: #{phrase}")

    worker = Claude.agents("developer", selected_config!().helpers)["kogen-worker"]
    assert worker["prompt"] =~ "actually run its assigned focused check"
    assert worker["prompt"] =~ "syntax-only check is not completion"
    assert worker["prompt"] =~ "without launching reviewer helpers"
    assert "Edit" in worker["tools"]
    # Built-in agents stay denied, so helpers cannot fan out into them.
    assert "Agent(general-purpose)" in Claude.disallowed_tools("developer")
  end

  test "the Developer delegation rule does not change Reviewer execution policy" do
    reviewer_policy = ExecutionPolicy.render(selected_config!(), "reviewer", @root)

    refute reviewer_policy =~ "## Build Developer work decomposition"
    assert reviewer_policy =~ "Configured root (reviewer): `gpt-6.1-sol` at `high`"
    assert reviewer_policy =~ "native kind `explorer`"
  end

  defp flat(text), do: String.replace(text, ~r/\s+/, " ")

  defp selected_config!(route \\ nil) do
    path = Path.join(@root, ".kogen/config.yaml")
    {:ok, config} = Intent.read_config(path, route)
    config
  end
end
