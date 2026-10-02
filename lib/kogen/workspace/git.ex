defmodule Kogen.Workspace.Git do
  @moduledoc false

  alias Kogen.Contracts.ProcResult

  @spec run(Path.t(), [String.t()], %{String.t() => String.t()}) ::
          {:ok, integer(), binary()} | {:error, term()}
  def run(repo, argv, git_env), do: run(repo, argv, git_env, nil)

  @spec run(Path.t(), [String.t()], %{String.t() => String.t()}, nil | {:binary, iodata()}) ::
          {:ok, integer(), binary()} | {:error, term()}
  def run(repo, argv, git_env, stdin) do
    log_path = Path.join(git_dir(repo), log_name())

    with :ok <- prepare_log(log_path) do
      options = [cd: repo, env: git_env, log_path: log_path]
      options = if is_nil(stdin), do: options, else: Keyword.put(options, :stdin, stdin)

      case Kogen.Workspace.Process.run(["git" | argv], options) do
        {:ok, %ProcResult{timed_out: true}} -> finish_run(log_path, {:error, :timeout})
        {:ok, %ProcResult{exit_status: status}} -> finish_run(log_path, {:ok, status})
        {:error, reason} -> finish_run(log_path, {:error, reason})
      end
    end
  end

  @spec private_index(Path.t()) :: Path.t()
  def private_index(repo) do
    Path.join(git_dir(repo), "kogen-index-#{System.pid()}-#{System.unique_integer([:positive])}")
  end

  @spec private_environment(%{String.t() => String.t()}, Path.t()) :: %{String.t() => String.t()}
  def private_environment(git_env, index_path), do: Map.put(git_env, "GIT_INDEX_FILE", index_path)

  @spec cleanup_index(Path.t()) :: :ok | {:error, term()}
  def cleanup_index(index_path) do
    with :ok <- remove_if_present(index_path) do
      remove_if_present(index_path <> ".lock")
    end
  end

  @spec git_dir(Path.t()) :: Path.t()
  def git_dir(repo) do
    git_entry = Path.join(repo, ".git")

    cond do
      File.dir?(git_entry) -> Path.expand(git_entry, "/")
      File.regular?(git_entry) -> git_file_dir(git_entry, repo)
      File.regular?(Path.join(repo, "HEAD")) -> Path.expand(repo, "/")
      true -> Path.expand(repo, "/")
    end
  end

  @spec valid_worktree_path?(Path.t()) :: boolean()
  def valid_worktree_path?(path) when is_binary(path) do
    Path.type(path) == :absolute and Path.basename(Path.dirname(path)) == "w" and
      Path.basename(path) not in ["", ".", "..", "w"]
  end

  def valid_worktree_path?(_path), do: false

  @spec safe_relative_path?(String.t()) :: boolean()
  def safe_relative_path?(path) when is_binary(path) do
    segments = String.split(path, "/")

    path != "" and Path.type(path) == :relative and not String.contains?(path, <<0>>) and
      Enum.all?(segments, &(&1 not in ["", ".", "..", ".git"]))
  end

  def safe_relative_path?(_path), do: false

  @spec safe_build_id?(String.t()) :: boolean()
  def safe_build_id?(build_id) when is_binary(build_id),
    do: Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]*\z/, build_id)

  def safe_build_id?(_build_id), do: false

  @spec nul_lines(binary()) :: [String.t()]
  def nul_lines(<<>>), do: []

  def nul_lines(output) do
    output
    |> String.split(<<0>>)
    |> Enum.reject(&(&1 == ""))
  end

  @spec trim_line(binary()) :: String.t()
  def trim_line(output), do: String.trim_trailing(output, "\n")

  @spec status_ok({:ok, integer(), binary()}) :: {:ok, binary()} | {:error, :git_failed}
  def status_ok({:ok, 0, output}), do: {:ok, output}
  def status_ok({:ok, _status, _output}), do: {:error, :git_failed}

  @spec status_ok({:error, term()} | {:ok, integer(), binary()}, atom()) ::
          {:ok, binary()} | {:error, term()}
  def status_ok({:error, reason}, _failure), do: {:error, reason}
  def status_ok({:ok, 0, output}, _failure), do: {:ok, output}
  def status_ok({:ok, _status, _output}, failure), do: {:error, failure}

  @spec remove_if_present(Path.t()) :: :ok | {:error, term()}
  def remove_if_present(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec git_file_dir(Path.t(), Path.t()) :: Path.t()
  defp git_file_dir(git_entry, repo) do
    case File.read(git_entry) do
      {:ok, "gitdir: " <> path} -> Path.expand(String.trim(path), repo)
      _result -> Path.expand(git_entry, "/")
    end
  end

  @spec prepare_log(Path.t()) :: :ok | {:error, term()}
  defp prepare_log(path) do
    with {:ok, file} <- File.open(path, [:write, :binary, :exclusive]) do
      chmod_result = File.chmod(path, 0o600)
      close_result = File.close(file)

      case {chmod_result, close_result} do
        {:ok, :ok} -> :ok
        {{:error, reason}, _close_result} -> cleanup_log(path, reason)
        {_chmod_result, {:error, reason}} -> cleanup_log(path, reason)
      end
    end
  end

  @spec cleanup_log(Path.t(), term()) :: {:error, term()}
  defp cleanup_log(path, reason) do
    case remove_if_present(path) do
      :ok -> {:error, reason}
      {:error, _cleanup_reason} -> {:error, :cleanup_failed}
    end
  end

  @spec finish_run(Path.t(), {:error, term()} | {:ok, integer()}) ::
          {:ok, integer(), binary()} | {:error, term()}
  defp finish_run(log_path, result) do
    output_result = File.read(log_path)
    cleanup_result = remove_if_present(log_path)

    case {result, output_result, cleanup_result} do
      {{:ok, status}, {:ok, output}, :ok} -> {:ok, status, output}
      {{:error, reason}, _output, :ok} -> {:error, reason}
      {_result, {:error, reason}, :ok} -> {:error, reason}
      {_result, _output, {:error, reason}} -> {:error, reason}
    end
  end

  @spec log_name() :: String.t()
  defp log_name do
    "kogen-git-#{System.pid()}-#{System.unique_integer([:positive])}.log"
  end
end
