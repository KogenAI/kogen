defmodule Kogen.Kernel.StateView do
  @moduledoc false

  alias Kogen.State
  alias Kogen.State.Event
  alias Kogen.State.Run

  @spec runs(Path.t(), String.t()) :: {:ok, [Run.t()]} | {:error, term()}
  def runs(state_root, slug) do
    with {:ok, all_runs} <- State.list(state_root) do
      {:ok, Enum.filter(all_runs, &(&1.slug == slug))}
    end
  end

  @spec latest([Run.t()]) :: {:ok, Run.t() | nil} | {:error, term()}
  def latest([]), do: {:ok, nil}

  def latest(runs) do
    runs
    |> Enum.reduce_while({:ok, []}, fn run, {:ok, dated} ->
      case run_timestamp(run) do
        {:ok, timestamp} -> {:cont, {:ok, [{timestamp, run} | dated]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, dated} -> {:ok, dated |> Enum.max_by(&elem(&1, 0)) |> elem(1)}
      error -> error
    end
  end

  @spec events(Run.t()) :: {:ok, [Event.t()]} | {:error, term()}
  def events(%Run{} = run) do
    path = Path.join(run.dir, "events.jsonl")

    case File.read(path) do
      {:ok, contents} -> decode_events(contents)
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_timestamp(%Run{} = run) do
    case File.stat(Path.join(run.dir, "run.json")) do
      {:ok, stat} -> {:ok, :calendar.datetime_to_gregorian_seconds(stat.mtime)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_events(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, events} ->
      case State.decode_event(line) do
        {:ok, event} -> {:cont, {:ok, [event | events]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      error -> error
    end
  rescue
    ArgumentError -> {:error, :invalid_event}
  end
end

defmodule Kogen.Kernel.Status do
  @moduledoc false

  alias Kogen.Kernel.StateView
  alias Kogen.Kernel.Types.IntentStatus
  alias Kogen.State
  alias Kogen.State.Run
  alias Kogen.Workspace

  @spec list(Path.t(), Path.t(), String.t(), map()) ::
          {:ok, [IntentStatus.t()]} | {:error, term()}
  def list(project_root, origin, base, git_env) do
    root = Path.join(project_root, ".kogen")

    project_root
    |> intent_paths()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, statuses} ->
      slug = path |> Path.dirname() |> Path.basename()

      case intent_status(origin, root, slug, base, git_env) do
        {:ok, status} -> {:cont, {:ok, [status | statuses]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, statuses} -> {:ok, Enum.reverse(statuses)}
      error -> error
    end
  rescue
    ArgumentError -> {:error, :status_unavailable}
  end

  defp intent_paths(project_root) do
    [project_root, ".kogen", "intents", "*", "intent.md"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.filter(&valid_slug?(Path.basename(Path.dirname(&1))))
    |> Enum.sort()
  end

  defp intent_status(origin, state_root, slug, base, git_env) do
    status = State.status(origin, state_root, slug, base, git_env)

    with {:ok, runs} <- StateView.runs(state_root, slug),
         {:ok, latest} <- StateView.latest(runs),
         {:ok, landed_sha} <- landed_sha(status, origin, base, runs, git_env) do
      {:ok,
       %IntentStatus{
         slug: slug,
         status: status,
         run_id: if(match?(%Run{}, latest), do: latest.id),
         landed_sha: landed_sha
       }}
    end
  end

  defp landed_sha(:landed, origin, base, runs, git_env) do
    with {:ok, branch_sha} <- Workspace.rev_parse(origin, "refs/heads/#{base}", git_env) do
      reachable = Enum.filter(runs, &reachable_run?(origin, &1, branch_sha, git_env))

      with {:ok, latest} <- StateView.latest(reachable) do
        {:ok, landing_sha(latest)}
      end
    end
  end

  defp landed_sha(_status, _origin, _base, _runs, _git_env), do: {:ok, nil}

  defp reachable_run?(origin, %Run{landing: landing}, branch_sha, git_env) when is_map(landing) do
    Workspace.ancestor?(origin, Map.get(landing, :candidate_commit), branch_sha, git_env)
  end

  defp reachable_run?(_origin, _run, _branch_sha, _git_env), do: false

  defp landing_sha(%Run{landing: landing}) when is_map(landing),
    do: Map.get(landing, :candidate_commit)

  defp landing_sha(nil), do: nil

  defp valid_slug?(slug), do: Regex.match?(~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, slug)
end

defmodule Kogen.Kernel.Reconcile do
  @moduledoc false

  alias Kogen.Proc
  alias Kogen.State

  @pid_liveness_script """
  use Errno qw(ESRCH EPERM);
  my $pid = shift @ARGV;
  local $! = 0;
  my $found = kill(0, $pid);
  exit 0 if $found;
  exit 1 if $! == ESRCH;
  exit 0 if $! == EPERM;
  exit 2;
  """

  @spec run(String.t(), Path.t(), Path.t(), String.t(), map()) ::
          {:ok, :landed | :unchanged} | {:error, term()}
  def run(run_id, project_root, origin, base, git_env) do
    state_root = Path.join(project_root, ".kogen")

    with {:ok, run} <- State.load(state_root, run_id) do
      case run.status do
        :running -> reconcile_unfinished(run, state_root, origin, git_env)
        _terminal -> State.reconcile(origin, state_root, run, base, git_env)
      end
    end
  end

  defp reconcile_unfinished(run, state_root, origin, git_env) do
    case owner_alive?(run.owner_os_pid, run.dir) do
      {:ok, true} ->
        {:ok, :unchanged}

      {:ok, false} ->
        with :ok <- State.recover_crashed(origin, state_root, run, git_env) do
          {:ok, :unchanged}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp owner_alive?(pid, directory) when is_integer(pid) and pid > 0 do
    case Proc.run(
           ["/usr/bin/perl", "-e", @pid_liveness_script, Integer.to_string(pid)],
           cd: directory
         ) do
      {:ok, %{exit_status: 0}} ->
        {:ok, true}

      {:ok, %{exit_status: 1}} ->
        {:ok, false}

      {:ok, %{exit_status: status, output_tail: output}} ->
        {:error, {:owner_liveness_check_failed, status, output}}

      {:error, reason} ->
        {:error, {:owner_liveness_check_failed, reason}}
    end
  end

  defp owner_alive?(_pid, _directory), do: {:ok, false}
end

defmodule Kogen.Kernel.Report do
  @moduledoc false

  alias Kogen.Kernel.StateView
  alias Kogen.State.Event
  alias Kogen.State.Run
  alias Kogen.Workspace

  @spec read(String.t(), Path.t(), Path.t(), String.t(), map()) ::
          {:ok, binary()} | {:error, term()}
  def read(slug, project_root, origin, base, git_env) do
    with {:ok, runs} <- StateView.runs(Path.join(project_root, ".kogen"), slug),
         {:ok, %Run{} = run} <- StateView.latest(runs),
         {:ok, events} <- StateView.events(run),
         {:ok, landed_sha} <- landed_sha(run, origin, base, git_env) do
      encode(run, events, landed_sha)
    else
      {:ok, nil} -> {:error, :missing_run}
      error -> error
    end
  end

  defp landed_sha(%Run{landing: nil}, _origin, _base, _git_env), do: {:ok, nil}

  defp landed_sha(%Run{landing: landing}, origin, base, git_env) do
    with {:ok, branch_sha} <- Workspace.rev_parse(origin, "refs/heads/#{base}", git_env) do
      if Workspace.ancestor?(origin, landing.candidate_commit, branch_sha, git_env),
        do: {:ok, landing.candidate_commit},
        else: {:ok, nil}
    end
  end

  defp encode(%Run{} = run, events, landed_sha) do
    report =
      json_object([
        {"slug", run.slug},
        {"status", Atom.to_string(run.status)},
        {"approval", nullable(run.approval_commit)},
        {"base",
         nullable(event_value(events, :base_sha) || landing_value(run, :expected_parent))},
        {"candidate", nullable(landing_value(run, :candidate_commit))},
        {"landed_sha", nullable(landed_sha)},
        {"acceptance_results", event_payload(events, "acceptance_result", :ledger, [])},
        {"check_receipts", event_payload(events, "check_result", :receipts, [])},
        {"model_stages", model_stages(events)},
        {"failures", failures(events)}
      ])

    {:ok, report |> :json.encode() |> IO.iodata_to_binary()}
  rescue
    ArgumentError -> {:error, :report_encoding_failed}
  end

  defp model_stages(events) do
    for %Event{event: "model_stage"} = event <- events do
      json_object([
        {"stage", event.stage},
        {"model", event.model},
        {"effort", event.effort},
        {"tokens", event.tokens}
      ])
    end
  end

  defp failures(events) do
    for %Event{event: "stage_failure"} = event <- events do
      json_object([
        {"stage", event.stage},
        {"class", event.class},
        {"reason", event.reason},
        {"detail", event.detail}
      ])
    end
  end

  defp event_value(events, key) do
    events
    |> Enum.reverse()
    |> Enum.find_value(&Map.get(&1, key))
  end

  defp event_payload(events, event_name, key, default) do
    events
    |> Enum.reverse()
    |> Enum.find_value(default, fn
      %Event{event: ^event_name} = event -> Map.get(event, key)
      _other -> nil
    end)
  end

  defp landing_value(%Run{landing: nil}, _key), do: nil
  defp landing_value(%Run{landing: landing}, :expected_parent), do: landing.expected_parent
  defp landing_value(%Run{landing: landing}, :candidate_commit), do: landing.candidate_commit

  defp json_object(pairs), do: Map.new(pairs)

  defp nullable(nil), do: :null
  defp nullable(value), do: value
end
