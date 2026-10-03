defmodule Kogen.State.RunStore do
  @moduledoc false

  alias Kogen.State.Approval
  alias Kogen.State.ApprovalStore
  alias Kogen.State.FileStore
  alias Kogen.State.Json
  alias Kogen.State.Run
  alias Kogen.State.Run.Landing

  @spec start_run(Path.t(), Approval.t()) :: {:ok, Run.t()} | {:error, term()}
  def start_run(root, %Approval{} = approval) do
    with :ok <- ApprovalStore.validate(approval),
         :ok <- absolute_root(root),
         runs_root = Path.join(root, "runs"),
         :ok <- File.mkdir_p(runs_root),
         {:ok, dir, id} <- create_run_dir(runs_root, 0) do
      run = %Run{
        id: id,
        dir: dir,
        slug: approval.slug,
        intent_sha256: approval.intent_sha256,
        target_branch: approval.target_branch,
        approval_commit: nil,
        status: :running,
        landing: nil,
        owner_os_pid: String.to_integer(System.pid())
      }

      with :ok <- File.mkdir_p(Path.join(dir, "transcripts")),
           :ok <- File.mkdir_p(Path.join(dir, "logs")),
           :ok <- persist(run) do
        {:ok, run}
      end
    end
  end

  @spec record(Run.t(), map()) :: :ok | {:error, term()}
  def record(%Run{} = run, event) when is_map(event) do
    with {:ok, encoded} <- Json.encode_event(event),
         {:ok, current} <- load_dir(run.dir),
         {:ok, with_landing} <- landing_from_event(current, event),
         :ok <- FileStore.append_line(Path.join(run.dir, "events.jsonl"), encoded),
         {:ok, updated} <- apply_event(with_landing, event) do
      persist(updated)
    end
  end

  @spec put_landing(Run.t(), map()) :: :ok | {:error, term()}
  def put_landing(%Run{} = run, identity) when is_map(identity) do
    with {:ok, current} <- load_dir(run.dir),
         {:ok, landing} <- landing(identity, current.id) do
      persist(%{current | landing: landing})
    end
  end

  @spec load(Path.t(), String.t()) :: {:ok, Run.t()} | {:error, term()}
  def load(root, id) when is_binary(root) and is_binary(id) do
    with :ok <- safe_id(id) do
      load_dir(Path.join([root, "runs", id]))
    end
  end

  @spec list(Path.t()) :: {:ok, [Run.t()]} | {:error, term()}
  def list(root) when is_binary(root) do
    runs_root = Path.join(root, "runs")

    case File.ls(runs_root) do
      {:ok, names} -> load_dirs(runs_root, names, [])
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp absolute_root(root) when is_binary(root) do
    if Path.type(root) == :absolute, do: :ok, else: {:error, :invalid_root}
  end

  defp absolute_root(_root), do: {:error, :invalid_root}

  defp create_run_dir(_root, attempts) when attempts >= 5, do: {:error, :run_id_collision}

  defp create_run_dir(root, attempts) do
    id = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    dir = Path.join(root, id)

    case File.mkdir(dir) do
      :ok -> {:ok, dir, id}
      {:error, :eexist} -> create_run_dir(root, attempts + 1)
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_dirs(_root, [], acc), do: {:ok, Enum.reverse(acc)}

  defp load_dirs(root, [name | rest], acc) do
    path = Path.join(root, name)

    if File.dir?(path) do
      case load_dir(path) do
        {:ok, run} -> load_dirs(root, rest, [run | acc])
        {:error, reason} -> {:error, reason}
      end
    else
      load_dirs(root, rest, acc)
    end
  end

  defp load_dir(dir) do
    with {:ok, contents} <- File.read(Path.join(dir, "run.json")) do
      Json.decode_run(contents, dir)
    end
  end

  defp landing_from_event(run, %{event: :landing_prepared, landing: identity})
       when is_map(identity) do
    with {:ok, landing} <- landing(identity, run.id) do
      {:ok, %{run | landing: landing}}
    end
  end

  defp landing_from_event(run, _event), do: {:ok, run}

  defp apply_event(run, event) do
    approval_commit = Map.get(event, :approval_commit, run.approval_commit)

    case Map.get(event, :status) do
      status when status in [:running, :landed, :failed, :parked] ->
        {:ok, %{run | approval_commit: approval_commit, status: status}}

      nil ->
        {:ok, %{run | approval_commit: approval_commit}}

      _other ->
        {:error, :invalid_run_status}
    end
  end

  defp landing(identity, run_id) do
    supplied_run_id = Map.get(identity, :run_id, run_id)

    values = %{
      approval_commit: Map.get(identity, :approval_commit),
      run_id: supplied_run_id,
      expected_parent: Map.get(identity, :expected_parent),
      final_tree: Map.get(identity, :final_tree),
      candidate_commit: Map.get(identity, :candidate_commit)
    }

    if supplied_run_id == run_id and Enum.all?(Map.values(values), &valid_identity_value?/1) do
      {:ok, struct!(Landing, values)}
    else
      {:error, :invalid_landing_identity}
    end
  end

  defp valid_identity_value?(value), do: is_binary(value) and value != ""

  defp persist(%Run{} = run) do
    with {:ok, encoded} <- Json.encode_run(run) do
      FileStore.atomic_write(Path.join(run.dir, "run.json"), encoded)
    end
  end

  defp safe_id(id) do
    if Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}\z/, id),
      do: :ok,
      else: {:error, :invalid_run_id}
  end
end
