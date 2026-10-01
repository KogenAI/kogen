defmodule Kh.Models do
  @moduledoc "ChatGPT Responses model settings retained by the custom runtime."

  @chatgpt_base_url "https://chatgpt.com/backend-api/codex"
  @levels ~w(off minimal low medium high xhigh max)
  @chatgpt_efforts %{"low" => "low", "medium" => "medium", "high" => "high", "xhigh" => "xhigh"}
  @chatgpt_max_models ~w(gpt-6-luna gpt-6-astra gpt-6.1-sol)

  def chatgpt_base_url, do: @chatgpt_base_url

  @doc "Build a Responses model descriptor for the caller-selected ChatGPT model."
  def chatgpt(id, overrides \\ %{}) when is_binary(id) and id != "" do
    efforts = if id in @chatgpt_max_models, do: Map.put(@chatgpt_efforts, "max", "max"), else: @chatgpt_efforts

    Map.merge(
      %{id: id, api: :responses, chatgpt: true, efforts: efforts, ctx: 272_000, price: nil},
      overrides
    )
  end

  @doc "Resolve supported effort. ChatGPT session admission rejects unsupported settings before use."
  def effort(_model, nil), do: {nil, "not requested"}

  def effort(model, level) when is_binary(level) do
    level = String.downcase(level)
    supported = model.efforts

    cond do
      Map.has_key?(supported, level) -> {supported[level], "as requested"}
      level in @levels -> {nil, "#{level} unsupported; omitted"}
      true -> {nil, "unknown effort #{level}; omitted"}
    end
  end

  def effort(_model, _level), do: {nil, "invalid effort; omitted"}

  def cost(_model, _usage), do: nil
end
