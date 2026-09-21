defmodule Kogen.ConfigurationSupportContractTest do
  use ExUnit.Case, async: true

  test "the production config consumer accepts supported values and rejects missing and foreign authority" do
    root = Path.join(System.tmp_dir!(), "kogen-config-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf(root) end)
    path = Path.join(root, "config.yaml")

    File.write!(path, """
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
    assert config.developer == %{model: "develop", effort: "medium"}
    assert config.helpers.worker.model == "worker"

    File.write!(path, "harness: codex\n")
    assert {:error, reason} = Kogen.Intent.read_config(path)
    assert reason =~ "missing required key: shaping"

    File.write!(path, """
    harness: foreign
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

    assert {:error, "unsupported harness: foreign; expected codex"} =
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
end
