defmodule Kogen.ClaudeCodeCatalogTest do
  @moduledoc """
  The proven Claude Code model picker: every entry cites retained evidence,
  the repository configuration selects only proven models and efforts, and
  Kogen never enables a fallback model.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @intent_id "01a0cc76-aac2-7130-9beb-48933506606d"

  test "the picker lists exactly the proven models, each citing retained evidence" do
    assert {:ok, models} = Kogen.Intent.claude_models()

    assert Enum.map(models, & &1["id"]) == ["claude-opus-5-5", "claude-sonnet-5"]

    for model <- models do
      assert model["efforts"] == ~w(low medium high xhigh)
      assert model["intent"] == @intent_id
      assert evidence_exists?(model["evidence"]), "missing evidence for #{model["id"]}"
    end

    refute Enum.any?(models, &String.contains?(&1["id"], "haiku"))
  end

  test "malformed pickers are refused rather than widened" do
    dir = Path.join(System.tmp_dir!(), "kogen-models-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    for {name, body} <- [
          {"empty", "models: []\n"},
          {"no-evidence", "models:\n  - {id: claude-opus-5-5, efforts: [low]}\n"},
          {"no-efforts", "models:\n  - {id: claude-opus-5-5, efforts: [], evidence: x}\n"}
        ] do
      path = Path.join(dir, name <> ".yaml")
      File.write!(path, body)
      assert {:error, reason} = Kogen.Intent.claude_models(path)
      assert reason =~ "invalid proven Claude Code model list"
    end
  end

  test "the repository selects Opus 5.5 roles at medium, an Opus expert at high and Sonnet 5 helpers" do
    assert {:ok, config} =
             Kogen.Intent.read_config(Path.join(@root, ".kogen/config.yaml"), "claude")

    assert config.harness == "claude"

    for role <- [:shaping, :developer, :reviewer],
        do: assert(Map.fetch!(config, role) == %{model: "claude-opus-5-5", effort: "medium"})

    assert config.helpers.expert == %{model: "claude-opus-5-5", effort: "high"}
    assert config.helpers.scout == %{model: "claude-sonnet-5", effort: "low"}
    assert config.helpers.worker == %{model: "claude-sonnet-5", effort: "medium"}
  end

  test "no Kogen launch enables a fallback model or intercepts provider requests" do
    sources =
      Path.wildcard(Path.join(@root, "lib/**/*.ex")) ++
        Path.wildcard(Path.join(@root, "priv/kogen/claude_code/*.{py,json,yaml}"))

    for path <- sources do
      text = File.read!(path)
      refute text =~ "--fallback-model", "#{path} must not enable a fallback model"
      refute text =~ "ANTHROPIC_BASE_URL\", \"", "#{path} must not route provider requests"
    end
  end

  defp evidence_exists?(relative) do
    complete = Path.join(@root, relative)
    approved = String.replace(complete, "/intents/complete/", "/intents/approved/")
    File.regular?(complete) or File.regular?(approved)
  end
end
