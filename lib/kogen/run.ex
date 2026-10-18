defmodule Kogen.Run do
  @moduledoc """
  A Build's run record (LOOP-10): `.kogen/local/runs/<build-id>/log.jsonl` with requests and
  usage, tool calls and results, verification passes, reviews and the outcome; `result.json`;
  `review-<n>.json`. Credentials never appear in it.
  """
  defstruct [:id, :dir, :log]

  def start(root) do
    id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    dir = Path.join(root, ".kogen/local/runs/#{id}")
    File.mkdir_p!(dir)
    %__MODULE__{id: id, dir: dir, log: Path.join(dir, "log.jsonl")}
  end

  def log(nil, _event), do: :ok

  def log(%__MODULE__{log: path}, event) do
    line = event |> Map.put("at", DateTime.utc_now() |> DateTime.to_iso8601()) |> JSON.encode!()
    File.write!(path, line <> "\n", [:append])
  end

  def write(%__MODULE__{dir: dir}, name, data),
    do: File.write!(Path.join(dir, name), JSON.encode!(data) <> "\n")

  @mib 1_048_576
  @doc "Output as recorded: at most 1 MiB."
  def cap(text) when byte_size(text) <= @mib, do: text

  def cap(text) do
    marker = "\n[... cut in the run log ...]\n"
    size = div(@mib - byte_size(marker), 2)
    head = valid_prefix(binary_part(text, 0, size))
    tail = valid_suffix(binary_part(text, byte_size(text) - size, size))
    head <> marker <> tail
  end

  defp valid_prefix(text),
    do:
      if(String.valid?(text),
        do: text,
        else: valid_prefix(binary_part(text, 0, byte_size(text) - 1))
      )

  defp valid_suffix(text),
    do:
      if(String.valid?(text),
        do: text,
        else: valid_suffix(binary_part(text, 1, byte_size(text) - 1))
      )
end
