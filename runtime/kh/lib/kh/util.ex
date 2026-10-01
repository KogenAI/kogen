defmodule Kh.Util do
  @moduledoc false

  def utf8(s) when is_binary(s), do: String.replace_invalid(s, "�")
  def utf8(s), do: to_string(s)

  def now_ms, do: System.monotonic_time(:millisecond)
  def iso_now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  def clip(s, n) when is_binary(s) do
    if String.length(s) > n, do: String.slice(s, 0, n) <> "...", else: s
  end

  def clip(s, n), do: clip(inspect(s), n)

  def resolve(path, cwd) do
    path = String.trim_leading(path, "@")

    cond do
      path == "~" -> System.user_home!()
      String.starts_with?(path, "~/") -> Path.join(System.user_home!(), binary_part(path, 2, byte_size(path) - 2))
      true -> Path.expand(path, cwd)
    end
  end
end
