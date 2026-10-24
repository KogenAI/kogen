defmodule Kogen.Provider do
  @moduledoc "Provider selection at the role boundary; omitted roles retain ChatGPT semantics."
  def name(role), do: Map.get(role, :provider, "chatgpt")

  def require_roles!(roles) do
    roles
    |> Enum.map(&name/1)
    |> Enum.uniq()
    |> Enum.each(fn
      "anthropic" -> Kogen.Anthropic.require_login!()
      "chatgpt" -> Kogen.ChatGPT.require_login!()
      "opencode-go" -> Kogen.OpenCodeGo.require_login!()
      "supergrok" -> Kogen.SuperGrok.require_login!()
    end)
  end

  def shape_roles(config) do
    [config.models["shape"]] ++
      if config.shape_workers.enabled,
        do: Enum.map(~w(read probe draft), &config.shape_workers[&1]),
        else: []
  end
end
