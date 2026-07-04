defmodule CodegenTestHarness.LoopQueueDrain do
  @moduledoc """
  Multi-pitch drain over `codegen/pitches/ready/`: reproduces
  `harnesses/shared/build-queue.sh`'s process contract on top of the shipped
  Elixir loop. Spawns one fresh `codegen-build` child per ordered pitch
  (zero cross-pitch context accumulation), transient-retries with backoff,
  enforces a per-pitch wall-clock budget/watchdog, stashes a dirty tree on
  timeout, and moves `ready/<slug>.md` to `shipped/<slug>.md` on child exit 0.

  Wires `CodegenTestHarness.LoopQueue.ordered_slugs/1` (topo-order,
  raise-on-cycle) and `LoopQueue.transient?/1` (JSONL classify) live — both
  were previously unreachable from any runtime caller.

  Old `build-queue.sh` `is_gate_green`/`mark_ship_progress`/
  `build-queue.json` position-manifest concerns are superseded by the
  child's exit code (0 = shipped, non-zero = not shipped) — not ported.

  Timeout is handled SEPARATELY from transient-retry classification: a
  watchdog timeout always stashes + retries-once + skips-on-second, and is
  never routed through `transient?/1` (mirrors old build-queue.sh where the
  timeout branch `continue`s before the transient-check block).
  """

  alias CodegenTestHarness.LoopQueue

  @type drain_opts :: keyword()

  @default_max_retries 3
  @default_retry_delays [30, 120, 300]
  @default_pitch_budget_secs 3600

  @codegen_build_bin Path.expand("../../../codegen-build", __DIR__)

  @doc """
  Drains `<cwd>/codegen/pitches/ready/` for `opts[:harness]`/`opts[:stack]`/
  `opts[:cwd]`. Returns `{:ok, shipped_count}` once `ready/` empties (either
  on the first scan — nothing to do — or after shipping every pitch that
  isn't left behind by a deterministic failure/skip). Returns
  `{:error, reason}` on a deterministic child failure, exhausted transient
  retries, or lock contention.

  Lets a dependency-cycle raise from `ordered_fn` (default
  `LoopQueue.ordered_slugs/1`) propagate uncaught — crash loud, never picks
  an arbitrary order.

  `opts` (all required unless noted; `_fn` seams default to the real
  implementation, override for tests):

    * `:harness` — `"claude"` | `"pi"` (required)
    * `:stack` — stack name, e.g. `"phoenix"` (required)
    * `:cwd` — project directory the drain operates in (required)
    * `:ready_dir` — default `Path.join([cwd, "codegen", "pitches", "ready"])`
    * `:shipped_dir` — default `Path.join([cwd, "codegen", "pitches", "shipped"])`
    * `:lock_path` — default `Path.join([cwd, "codegen", "pitches", "queue.lock"])`
    * `:max_retries` — default 3 (env `CODEGEN_BUILD_QUEUE_MAX_RETRIES`)
    * `:retry_delays` — default `[30, 120, 300]` (env `CODEGEN_BUILD_QUEUE_RETRY_DELAYS`)
    * `:pitch_budget_secs` — default 3600 (env `CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS`)
    * `:spawn_fn` — `(slug, harness, stack, cwd, jsonl_path -> {:exit_code, integer} | :timeout)`
    * `:sleep_fn` — `(secs -> :ok)`
    * `:git_stash_fn` — `(cwd, slug -> :ok | {:error, reason})`
    * `:now_fn` — `(-> integer unix secs)`
    * `:ordered_fn` — `(ready_dir -> [slug])`, default `LoopQueue.ordered_slugs/1`
    * `:transient_fn` — `(jsonl_path -> boolean)`, default `LoopQueue.transient?/1`
    * `:pid_alive_fn` — `(pid -> boolean)`, default checks `/proc`-independent
      via `System.cmd("kill", ["-0", pid])` exit status
  """
  @spec drain(drain_opts()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def drain(opts) do
    harness = Keyword.fetch!(opts, :harness)
    stack = Keyword.fetch!(opts, :stack)
    cwd = Keyword.fetch!(opts, :cwd)

    ready_dir = Keyword.get(opts, :ready_dir, Path.join([cwd, "codegen", "pitches", "ready"]))

    shipped_dir =
      Keyword.get(opts, :shipped_dir, Path.join([cwd, "codegen", "pitches", "shipped"]))

    lock_path =
      Keyword.get(opts, :lock_path, Path.join([cwd, "codegen", "pitches", "queue.lock"]))

    File.mkdir_p!(ready_dir)
    File.mkdir_p!(shipped_dir)
    File.mkdir_p!(Path.dirname(lock_path))

    pid_alive_fn = Keyword.get(opts, :pid_alive_fn, &default_pid_alive?/1)

    case acquire_lock(lock_path, pid_alive_fn) do
      :ok ->
        try do
          state = %{
            harness: harness,
            stack: stack,
            cwd: cwd,
            ready_dir: ready_dir,
            shipped_dir: shipped_dir,
            max_retries: Keyword.get(opts, :max_retries, max_retries_from_env()),
            retry_delays: Keyword.get(opts, :retry_delays, retry_delays_from_env()),
            pitch_budget_secs: Keyword.get(opts, :pitch_budget_secs, pitch_budget_from_env()),
            spawn_fn: Keyword.get(opts, :spawn_fn, &default_spawn_fn/5),
            sleep_fn: Keyword.get(opts, :sleep_fn, &default_sleep_fn/1),
            git_stash_fn: Keyword.get(opts, :git_stash_fn, &default_git_stash_fn/2),
            now_fn: Keyword.get(opts, :now_fn, &default_now_fn/0),
            ordered_fn: Keyword.get(opts, :ordered_fn, &LoopQueue.ordered_slugs/1),
            transient_fn: Keyword.get(opts, :transient_fn, &LoopQueue.transient?/1),
            timed_out_slugs: MapSet.new(),
            retry_count: 0,
            last_slug: nil
          }

          run_loop(state, 0)
        after
          release_lock(lock_path)
        end

      {:error, _reason} = err ->
        err
    end
  end

  # ── Lock ──────────────────────────────────────────────────────────────────

  defp acquire_lock(lock_path, pid_alive_fn) do
    case File.read(lock_path) do
      {:ok, content} ->
        case String.split(String.trim(content), " ", parts: 2) do
          [pid_str | _] when pid_str != "" ->
            if pid_alive_fn.(pid_str) do
              {:error,
               "queue: a build is already running (pid #{pid_str}) — refusing to start a second"}
            else
              write_lock(lock_path)
            end

          _ ->
            write_lock(lock_path)
        end

      {:error, _reason} ->
        write_lock(lock_path)
    end
  end

  defp write_lock(lock_path) do
    File.write!(lock_path, "#{System.pid()} queue\n")
    :ok
  end

  defp release_lock(lock_path) do
    File.rm(lock_path)
    :ok
  end

  defp default_pid_alive?(pid_str) do
    case Integer.parse(pid_str) do
      {pid, ""} ->
        case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
          {_out, 0} -> true
          {_out, _} -> false
        end

      _ ->
        false
    end
  end

  # ── Main loop ─────────────────────────────────────────────────────────────

  defp run_loop(state, shipped_count) do
    ordered = state.ordered_fn.(state.ready_dir)

    remaining =
      Enum.reject(ordered, fn slug -> MapSet.member?(state.timed_out_slugs, slug) end)

    case remaining do
      [] ->
        {:ok, shipped_count}

      [slug | _] ->
        run_slug(state, slug, shipped_count)
    end
  end

  defp run_slug(state, slug, shipped_count) do
    ts = state.now_fn.()
    jsonl = Path.join([state.cwd, "codegen", "logging", "#{ts}_#{slug}_build.jsonl"])
    File.mkdir_p!(Path.dirname(jsonl))

    case state.spawn_fn.(slug, state.harness, state.stack, state.cwd, jsonl) do
      {:exit_code, 0} ->
        ship(state.ready_dir, state.shipped_dir, slug)
        state = %{state | retry_count: 0, last_slug: nil}
        run_loop(state, shipped_count + 1)

      {:exit_code, _n} ->
        handle_nonzero_exit(state, slug, jsonl, shipped_count)

      :timeout ->
        handle_timeout(state, slug, shipped_count)
    end
  end

  defp ship(ready_dir, shipped_dir, slug) do
    src = Path.join(ready_dir, "#{slug}.md")
    dst = Path.join(shipped_dir, "#{slug}.md")
    File.rename!(src, dst)
    :ok
  end

  defp handle_nonzero_exit(state, slug, jsonl, shipped_count) do
    retry_count = if state.last_slug == slug, do: state.retry_count, else: 0

    if state.transient_fn.(jsonl) and retry_count < state.max_retries do
      attempt = retry_count + 1
      delay = pick_delay(state.retry_delays, attempt)
      if delay > 0, do: state.sleep_fn.(delay)

      state = %{state | retry_count: attempt, last_slug: slug}
      run_slug(state, slug, shipped_count)
    else
      {:error, "queue: #{slug} failed (deterministic or retries exhausted)"}
    end
  end

  defp handle_timeout(state, slug, shipped_count) do
    case state.git_stash_fn.(state.cwd, slug) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end

    if MapSet.member?(state.timed_out_slugs, {:once, slug}) do
      # second timeout for this slug — mark skipped for the remainder of this run
      state = %{
        state
        | timed_out_slugs: MapSet.put(state.timed_out_slugs, slug),
          retry_count: 0,
          last_slug: nil
      }

      run_loop(state, shipped_count)
    else
      # first timeout — retry once
      state = %{
        state
        | timed_out_slugs: MapSet.put(state.timed_out_slugs, {:once, slug}),
          retry_count: 0,
          last_slug: nil
      }

      run_slug(state, slug, shipped_count)
    end
  end

  # ── Backoff ───────────────────────────────────────────────────────────────

  @spec pick_delay([non_neg_integer()], pos_integer()) :: non_neg_integer()
  defp pick_delay(delays, attempt) do
    idx = min(attempt, length(delays)) - 1
    Enum.at(delays, idx, List.last(delays) || 0)
  end

  # ── Env-toggle resolution ────────────────────────────────────────────────

  @doc "Resolves `CODEGEN_BUILD_QUEUE_MAX_RETRIES`, default #{@default_max_retries}."
  @spec max_retries_from_env() :: pos_integer()
  def max_retries_from_env do
    case System.get_env("CODEGEN_BUILD_QUEUE_MAX_RETRIES") do
      nil -> @default_max_retries
      str -> parse_pos_int(str, @default_max_retries)
    end
  end

  @doc "Resolves `CODEGEN_BUILD_QUEUE_RETRY_DELAYS` (space-separated seconds), default #{inspect(@default_retry_delays)}."
  @spec retry_delays_from_env() :: [non_neg_integer()]
  def retry_delays_from_env do
    case System.get_env("CODEGEN_BUILD_QUEUE_RETRY_DELAYS") do
      nil ->
        @default_retry_delays

      str ->
        parsed =
          str
          |> String.split(" ", trim: true)
          |> Enum.map(&Integer.parse/1)
          |> Enum.filter(&match?({_n, ""}, &1))
          |> Enum.map(&elem(&1, 0))

        if parsed == [], do: @default_retry_delays, else: parsed
    end
  end

  @doc "Resolves `CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS`, default #{@default_pitch_budget_secs}; 0/non-numeric → default."
  @spec pitch_budget_from_env() :: pos_integer()
  def pitch_budget_from_env do
    case System.get_env("CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS") do
      nil ->
        @default_pitch_budget_secs

      str ->
        case Integer.parse(str) do
          {n, ""} when n > 0 -> n
          _ -> @default_pitch_budget_secs
        end
    end
  end

  defp parse_pos_int(str, default) do
    case Integer.parse(str) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  @doc "Mention prefix for `harness`: `\"claude\"` -> `\"@\"`, `\"pi\"` -> `\"\"`."
  @spec mention_prefix(String.t()) :: String.t()
  def mention_prefix("claude"), do: "@"
  def mention_prefix("pi"), do: ""
  def mention_prefix(other), do: raise("LoopQueueDrain: unknown harness #{inspect(other)}")

  @doc false
  @spec pitch_arg_for(String.t(), String.t(), String.t()) :: String.t()
  def pitch_arg_for(slug, harness, cwd) do
    mention_prefix(harness) <> Path.join(cwd, "codegen/pitches/ready/#{slug}.md")
  end

  # ── Real spawn_fn: fresh codegen-build child, budget-bounded, JSONL capture ──

  @doc false
  @spec default_spawn_fn(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:exit_code, integer()} | :timeout
  def default_spawn_fn(slug, harness, stack, cwd, jsonl_path) do
    unless File.exists?(@codegen_build_bin) do
      raise "LoopQueueDrain: codegen-build not found at #{@codegen_build_bin}"
    end

    pitch_arg = pitch_arg_for(slug, harness, cwd)

    args = [
      "--harness=#{harness}",
      "--non-interactive",
      "--stack=#{stack}",
      "--cwd=#{cwd}",
      "--",
      pitch_arg
    ]

    env = [
      {"PATH", System.get_env("PATH") || ""},
      {"CLAUDE_ASYNC_AGENT_STALL_TIMEOUT_MS", "0"},
      {"CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS", "0"},
      {"CLAUDE_STREAM_IDLE_TIMEOUT_MS", "0"}
    ]

    budget_secs = pitch_budget_from_env()

    task =
      Task.async(fn ->
        System.cmd(@codegen_build_bin, args, cd: cwd, env: env, stderr_to_stdout: true)
      end)

    case Task.yield(task, budget_secs * 1000) do
      {:ok, {output, exit_code}} ->
        File.write!(jsonl_path, output)
        {:exit_code, exit_code}

      nil ->
        Task.shutdown(task, :brutal_kill)
        :timeout
    end
  end

  @doc false
  @spec default_sleep_fn(non_neg_integer()) :: :ok
  def default_sleep_fn(secs) do
    Process.sleep(secs * 1000)
    :ok
  end

  @doc false
  @spec default_now_fn() :: integer()
  def default_now_fn, do: System.system_time(:second)

  # ── Real git_stash_fn: tracked-only, fail-open ──────────────────────────────

  @doc false
  @spec default_git_stash_fn(String.t(), String.t()) :: :ok | {:error, String.t()}
  def default_git_stash_fn(cwd, slug) do
    with {_out, 0} <-
           System.cmd("git", ["-C", cwd, "rev-parse", "--git-dir"], stderr_to_stdout: true),
         {status, 0} <-
           System.cmd("git", ["-C", cwd, "status", "--porcelain"], stderr_to_stdout: true) do
      tracked_dirty? =
        status
        |> String.split("\n", trim: true)
        |> Enum.any?(&(not String.starts_with?(&1, "??")))

      if tracked_dirty? do
        msg = "queue-timeout:#{slug}:#{default_now_fn()}"

        case System.cmd("git", ["-C", cwd, "stash", "push", "-u", "-m", msg],
               stderr_to_stdout: true
             ) do
          {_out, 0} -> :ok
          {out, _} -> {:error, "git stash failed: #{out}"}
        end
      else
        :ok
      end
    else
      {out, _code} -> {:error, "not a git repo or git status failed: #{out}"}
    end
  end
end
