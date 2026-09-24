defmodule Kogen.ConfigurationSupportContractTest do
  use ExUnit.Case, async: true

  @config_path ".kogen/config.yaml"
  @readme Path.expand("../../README.md", __DIR__) |> File.read!()

  test "the tracked config keeps Claude as the repository default" do
    assert {:ok, config} = Kogen.Intent.read_config(@config_path)

    assert config.route == "claude"
    assert config.harness == "claude"
    assert config.shaping == %{model: "claude-opus-5-5", effort: "medium"}
    assert config.developer == %{model: "claude-opus-5-5", effort: "medium"}
    assert config.reviewer == %{model: "claude-opus-5-5", effort: "medium"}
    assert config.helpers.scout == %{model: "claude-sonnet-5", effort: "low"}
    assert config.helpers.worker == %{model: "claude-sonnet-5", effort: "medium"}
    assert config.helpers.expert == %{model: "claude-opus-5-5", effort: "high"}
    assert config.outer_resumptions == 2
    assert config.verification_retries == 2
  end

  test "the tracked config resolves the codex route with the exact profiles" do
    assert {:ok, config} = Kogen.Intent.read_config(@config_path, "codex")

    assert config.route == "codex"
    assert config.harness == "codex"
    assert config.shaping == %{model: "gpt-6-sol", effort: "medium"}
    assert config.developer == %{model: "gpt-6-sol", effort: "medium"}
    assert config.reviewer == %{model: "gpt-6-sol", effort: "high"}
    assert config.helpers.scout == %{model: "gpt-6-luna", effort: "low"}
    assert config.helpers.worker == %{model: "gpt-6-luna", effort: "high"}
    assert config.helpers.expert == %{model: "gpt-6-sol", effort: "high"}
    assert config.outer_resumptions == 2
    assert config.verification_retries == 2
  end

  test "the production config consumer accepts supported values and rejects missing and foreign authority" do
    root = Path.join(System.tmp_dir!(), "kogen-config-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf(root) end)
    path = Path.join(root, "config.yaml")

    File.write!(path, """
    default_route: primary
    routes:
      primary:
        harness: codex
        shaping: {model: shape, effort: low}
        developer: {model: develop, effort: medium}
        reviewer: {model: review, effort: high}
        helpers:
          scout: {model: scout, effort: low}
          worker: {model: worker, effort: medium}
          expert: {model: expert, effort: high}
    outer_resumptions: 2
    verification_retries: 1
    """)

    assert {:ok, config} = Kogen.Intent.read_config(path)
    assert config.route == "primary"
    assert config.developer == %{model: "develop", effort: "medium"}
    assert config.helpers.worker.model == "worker"

    assert {:error, "unknown route: missing; available routes: primary"} =
             Kogen.Intent.read_config(path, "missing")

    File.write!(path, """
    default_route: primary
    routes:
      primary:
        harness: codex
    outer_resumptions: 2
    verification_retries: 1
    """)

    assert {:error, reason} = Kogen.Intent.read_config(path)
    assert reason =~ "missing required key: routes.primary.shaping"

    File.write!(path, "harness: codex\n")

    assert {:error,
            "config.yaml uses the replaced flat configuration shape (top-level harness and roles); define default_route and routes instead"} =
             Kogen.Intent.read_config(path)
  end

  test "provider denial shim is executable and records attempted access outside the fixture" do
    root = Path.expand("../..", __DIR__)
    shim = Path.join(root, "test/support/codex")
    assert File.regular?(shim)
    assert {:ok, stat} = File.stat(shim)
    assert Bitwise.band(stat.mode, 0o111) != 0

    receipt =
      Path.join(System.tmp_dir!(), "provider-denied-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm(receipt) end)

    {_output, status} =
      System.cmd(shim, ["exec"],
        env: [{"KOGEN_PROVIDER_DENIAL_RECEIPT", receipt}],
        stderr_to_stdout: true
      )

    assert status != 0
    assert File.read!(receipt) =~ "PATH-SHIM-CODEX-INVOKED: exec"
  end

  test "README documents routes, --route selection, default_route, flat-shape refusal and route recording" do
    assert @readme =~ "routes"
    assert @readme =~ "default_route"
    assert @readme =~ "--route <name>"
    assert @readme =~ "mix kogen.shape"
    assert @readme =~ "mix kogen.build"

    assert @readme =~
             "top-level `harness:` and roles, no `routes`) is refused before launch"

    assert @readme =~ "shaping.route"
    assert @readme =~ "resolves its route once and freezes it"
    assert @readme =~ "build-summary.json"
  end

  test "README no longer claims a single global harness is what the config names" do
    refute @readme =~ "the configured harness"
    refute @readme =~ "This repository's current\nconfiguration"
  end
end
