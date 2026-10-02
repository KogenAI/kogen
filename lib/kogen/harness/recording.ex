defmodule Kogen.Harness.Recording do
  @moduledoc false

  alias Kogen.Harness.Codec
  alias Kogen.Harness.Error
  alias Kogen.Harness.Opts
  alias Kogen.Harness.Paths
  alias Kogen.Harness.TranscriptEntry

  @spec path(Opts.t()) :: {:ok, Path.t()} | {:error, Error.t()}
  def path(%Opts{} = opts) do
    with {:ok, run_dir} <- Paths.run_dir(opts),
         :ok <- File.mkdir_p(run_dir) do
      {:ok, Path.join(run_dir, "transcript.jsonl")}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        error(:run_directory_failed, "Cannot create run directory: #{inspect(reason)}")
    end
  end

  @spec append(Opts.t(), atom(), atom(), non_neg_integer(), term()) :: :ok | {:error, Error.t()}
  def append(%Opts{} = opts, event, stage, turn, payload) do
    with {:ok, transcript_path} <- path(opts),
         {:ok, line} <-
           Codec.encode_entry(%TranscriptEntry{
             event: event,
             stage: stage,
             turn: turn,
             payload: payload
           }),
         :ok <- append_line(transcript_path, line) do
      :ok
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        error(:transcript_write_failed, "Cannot append transcript entry: #{inspect(reason)}")
    end
  end

  defp append_line(path, line), do: File.write(path, line <> "\n", [:append])
  defp error(reason, detail), do: {:error, %Error{reason: reason, detail: detail}}
end
