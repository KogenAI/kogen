defmodule Kogen.ProviderTest do
  use ExUnit.Case, async: true
  alias Kogen.{ChatGPT, Config, Provider}

  test "Shape includes enabled workers but Refine can select only the Shape role" do
    config = %Config{models: Config.default_models(), shape_workers: %{enabled: false}}
    assert Provider.shape_roles(config) == [config.models["shape"]]

    workers = %{
      "read" => %{provider: "supergrok", model: "grok-4.7", effort: "low"},
      "probe" => %{model: "fixture", effort: "medium"},
      "draft" => %{provider: "chatgpt", model: "fixture", effort: "high"},
      enabled: true
    }

    assert Enum.map(Provider.shape_roles(%{config | shape_workers: workers}), &Provider.name/1) ==
             ["chatgpt", "supergrok", "chatgpt", "chatgpt"]
  end

  test "SuperGrok plain policy and cache uncertainty are explicitly provider scoped" do
    # A GPT-looking model must not enable cache on a SuperGrok route.
    for model <- ["grok-4.7", "gpt-6.1-sol"] do
      body =
        ChatGPT.request_body(
          %{provider: "supergrok", model: model, effort: "high"},
          "policy",
          [%{"role" => "user", "content" => "input"}],
          []
        )

      assert body["instructions"] == "policy"

      assert body["input"] == [
               %{"role" => "user", "content" => [%{"type" => "input_text", "text" => "input"}]}
             ]

      refute Map.has_key?(body, "prompt_cache_options")
      {_, _, meta} = Process.get(:prompt_cache_current)
      assert meta.cache.status == "unknown"
      assert meta.cache.boundaries == []
    end
  end
end
