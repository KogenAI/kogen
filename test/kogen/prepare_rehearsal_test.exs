Code.require_file("../support/prepare_rehearsal.ex", __DIR__)

defmodule Kogen.PrepareRehearsalTest do
  @moduledoc """
  Regression for the seq30 verification failure: `scripts/check/rehearsals.exs`
  required `Kogen.ReviewPacketAudit.claude_scope_ready?` from the
  `live-reviewer-rework` prepare although the gate ran on the Build's outer
  `codex` route, whose roles never launch Claude. The prepare now runs on the
  Build's selected route and its required owner entry points follow the
  harnesses that route's roles use.
  """
  use ExUnit.Case, async: true

  alias Kogen.{Intent, PrepareRehearsal}

  @root Path.expand("../..", __DIR__)
  @config Path.join(@root, ".kogen/config.yaml")
  @scope_entries [
    "Kogen.ManagedRuntimeReady.prepare!",
    "Kogen.ReviewPacketAudit.claude_scope_ready?",
    "Kogen.ReviewPacketAudit.codex_scope_ready?",
    "Kogen.ReviewPacketAudit.hook_toolchain_ready?"
  ]

  defp route!(name) do
    assert {:ok, config} = Intent.read_config(@config, name)
    config
  end

  test "harnesses lists each distinct harness the route's roles run on" do
    assert Intent.harnesses(route!("codex")) == ["codex"]
    assert Intent.harnesses(route!("claude")) == ["claude"]
    assert Enum.sort(Intent.harnesses(route!("optimum"))) == ["claude", "codex"]
  end

  test "the selected route wins; only without one is the config's default_route used" do
    assert PrepareRehearsal.selected_config!(@root, "codex").route == "codex"
    assert PrepareRehearsal.selected_config!(@root, "claude").route == "claude"
    assert PrepareRehearsal.selected_config!(@root, nil).route == "optimum"
    assert PrepareRehearsal.selected_config!(@root, "").route == "optimum"
  end

  test "required scope entry points follow the route's harnesses" do
    codex = PrepareRehearsal.required_trace(@scope_entries, route!("codex"))
    refute "Kogen.ReviewPacketAudit.claude_scope_ready?" in codex
    assert "Kogen.ReviewPacketAudit.codex_scope_ready?" in codex

    claude = PrepareRehearsal.required_trace(@scope_entries, route!("claude"))
    assert "Kogen.ReviewPacketAudit.claude_scope_ready?" in claude
    refute "Kogen.ReviewPacketAudit.codex_scope_ready?" in claude

    hybrid = PrepareRehearsal.required_trace(@scope_entries, route!("optimum"))
    assert hybrid == @scope_entries

    for required <- [codex, claude, hybrid] do
      assert "Kogen.ManagedRuntimeReady.prepare!" in required
      assert "Kogen.ReviewPacketAudit.hook_toolchain_ready?" in required
    end
  end

  test "a route harness the catalog declares no scope check for is refused, not skipped" do
    entries = List.delete(@scope_entries, "Kogen.ReviewPacketAudit.claude_scope_ready?")

    assert_raise RuntimeError,
                 ~r/declare no scope check for route "optimum" harness claude/,
                 fn ->
                   PrepareRehearsal.required_trace(entries, route!("optimum"))
                 end
  end

  test "targets that declare no scope entry points are unchanged by any route" do
    entries = ["driver.prepare_login_scope_ok", "driver.setup_fixture"]

    for route <- ["codex", "claude", "optimum"] do
      assert PrepareRehearsal.required_trace(entries, route!(route)) == entries
    end
  end

  test "every tracked live target's declared prepare entry points hold on every tracked route" do
    catalog = YamlElixir.read_from_file!(Path.join(@root, "priv/kogen/verification_targets.yaml"))
    config = YamlElixir.read_from_file!(@config)

    prepares = Enum.filter(catalog["targets"], &Map.has_key?(&1, "prepare"))
    assert prepares != []

    for route <- Map.keys(config["routes"]), target <- prepares do
      entries = get_in(target, ["rehearsal", "prepare_trace_assertions"])
      required = PrepareRehearsal.required_trace(entries, route!(route))

      assert required != [], "#{target["name"]} requires no trace on route #{route}"
      assert required -- entries == []
    end
  end
end
