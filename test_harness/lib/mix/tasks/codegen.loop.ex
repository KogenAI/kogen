defmodule Mix.Tasks.Codegen.Loop do
  @shortdoc "Runs the deterministic orchestration loop for one pitch."

  @moduledoc """
  `mix codegen.loop --harness=<claude_code|pi> --stack=<phoenix|static> --cwd=<dir> [--fallback-model=<m>] [--max-budget-usd=<n>] <pitch>`

  Execs from the build-mode `dispatch.sh` path in place of a single
  self-orchestrating agent session. Runs `CodegenTestHarness.OrchestrationLoop.run/1`
  and exits:

  - `0` — cycle reached COMMITTED with a clear gate
  - `4` — COMMITTED and RETIRED (the pitch's work landed and left ready/ or
    building/ for shipped/, unconditionally), but the working tree was
    dirty at ship time — a ship-with-warning, not a failure. See
    `@dirty_tree_exit_code` and `warn_dirty_after_retire/1`.
  - non-zero, reason on stderr — any other failure (crash loud; no silent
    success)

  ## Flags

  - `--harness` — required, `claude_code` | `pi`
  - `--stack` — required, `phoenix` | `static`
  - `--cwd` — required, project directory the loop operates in
  - `--fallback-model` — optional. Prepends `<m>` as rung 0 of EVERY role's
    `fallback:` chain for this run only (a one-build override of
    `templates/generator/config.yaml`, threaded from `codegen-build
    --fallback-model=<m>` via `CODEGEN_BUILD_FALLBACK_MODEL`). Absent →
    every role's chain is exactly what `config.yaml` declares, unchanged.
  - `--max-budget-usd` — optional. Once accumulated spend (summed across every
    role invocation, including gate retries) reaches this many USD, the loop
    aborts BETWEEN role invocations (the in-flight role always completes —
    its cost is already committed to the API). Threaded from `codegen-build
    --max-budget-usd=<n>` via `CODEGEN_BUILD_MAX_BUDGET_USD`. Absent → no cap,
    exactly today's behavior.
  - `<pitch>` — required positional arg, the prompt/pitch text (or `@<path>`
    to read it from a file, matching `codegen-call`'s `@<path>` convention)
  """

  use Mix.Task

  alias CodegenTestHarness.BuildSignalHandler
  alias CodegenTestHarness.InfraAbort
  alias CodegenTestHarness.LoopQueue
  alias CodegenTestHarness.OrchestrationLoop

  # Distinct exit code for an infra abort (a fault no developer edit could
  # fix — see `CodegenTestHarness.InfraAbort`), separate from `1`
  # (deterministic cycle failure) and `2` (usage/flag error). This is the
  # signal `LoopQueueDrain` needs to tell "the box is broken" apart from
  # "this pitch's diff didn't pass" — both would otherwise be an
  # indistinguishable non-zero exit.
  @infra_abort_exit_code 3

  # Distinct exit code for "the pitch's work landed AND was retired, but
  # the working tree was dirty at ship time" (see `warn_dirty_after_retire/1`).
  # This is NOT a failure — the commit landed, the pitch left ready/ and is
  # in shipped/ — but it is not a silent success either, since something
  # (stray render artifacts, a leftover edit) is sitting uncommitted. Distinct
  # from `1` (deterministic cycle failure, pitch NOT retired) so
  # `LoopQueueDrain` can count this as a ship-with-warning rather than
  # requeue a pitch whose work is already on develop (see
  # codegen/pitches/shipped/a-landed-pitch-cannot-be-handed-out-again.md).
  @dirty_tree_exit_code 4

  @impl Mix.Task
  def run(argv) do
    {opts, positional, invalid} =
      OptionParser.parse(argv,
        strict: [
          harness: :string,
          stack: :string,
          cwd: :string,
          fallback_model: :string,
          max_budget_usd: :float
        ]
      )

    if invalid != [] do
      Mix.shell().error("codegen.loop: invalid flags: #{inspect(invalid)}")
      exit({:shutdown, 2})
    end

    harness = Keyword.get(opts, :harness) || missing_flag!("--harness")
    stack = Keyword.get(opts, :stack) || missing_flag!("--stack")
    cwd = Keyword.get(opts, :cwd) || missing_flag!("--cwd")
    # Optional: absent -> nil -> OrchestrationLoop.run/1 does not override
    # any role's fallback chain, exactly today's behavior.
    fallback_model = Keyword.get(opts, :fallback_model)
    # Optional: absent -> nil -> OrchestrationLoop.run/1 enforces no spend
    # cap, exactly today's behavior.
    max_budget_usd = Keyword.get(opts, :max_budget_usd)

    # Move 2: install the SIGTERM handler for the solo path (SIGINT cannot
    # be caught at the BEAM level — see BuildSignalHandler moduledoc; the
    # bash dispatch layer forwards SIGINT as SIGTERM to this process group).
    # Unlike the queue drain (which tracks a Port os_pid), this path's heavy
    # subprocess runs via synchronous `System.cmd/3` with no exposed os_pid
    # — the reap here targets THIS process's own OS descendant subtree
    # (`LoopQueueDrain.reap_own_descendants/0`) rather than a single tracked
    # child.
    lock_path = Path.join([cwd, "codegen", "gate-pending", "queue.lock"])

    :ok =
      BuildSignalHandler.install(lock_path,
        reap_fn: &CodegenTestHarness.LoopQueueDrain.reap_own_descendants/0
      )

    pitch_arg =
      case positional do
        [pitch_arg | _] -> pitch_arg
        [] -> missing_flag!("<pitch>")
      end

    pitch = resolve_pitch(pitch_arg, cwd)
    source = resolve_pitch_source(pitch_arg, cwd)

    # Possession by rename: a pitch selected from ready/ is claimed into
    # building/ for the duration of this cycle — a second builder racing on
    # the same slug hits ENOENT (physics, not policy). See claim_pitch!/2.
    source = claim_pitch!(source, cwd)

    slug =
      case source do
        {:file, abs} -> Path.basename(abs, ".md")
        :literal -> "adhoc"
      end

    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")
    cycle_id = "#{stamp}_#{slug}"

    head_before = git_head(cwd)

    result =
      run_loop_catching_infra_abort(fn ->
        OrchestrationLoop.run(
          harness: harness,
          stack: stack,
          cwd: cwd,
          pitch: pitch,
          cycle_id: cycle_id,
          slug: slug,
          stamp: stamp,
          fallback_model_override: fallback_model,
          max_budget_usd: max_budget_usd
        )
      end)

    # Emit aggregated per-cycle telemetry as a parseable stream-json result line
    # (benchmark instrumentation) regardless of outcome — a failed cycle still
    # spent tokens and its cost belongs in the A/B.
    emit_loop_telemetry(result)

    case result do
      :ok ->
        case verify_commit_landed(head_before, cwd) do
          {:ok, after_sha} ->
            Mix.shell().info("codegen.loop: COMMITTED, gate clear")
            maybe_ship_pitch(source, cwd, before_sha(head_before), after_sha)

          {:error, reason} ->
            restore_claim(source, cwd)
            Mix.shell().error("codegen.loop: FAILED — #{reason}")
            exit({:shutdown, 1})
        end

      {:error, reason} ->
        restore_claim(source, cwd)
        Mix.shell().error("codegen.loop: FAILED — #{reason}")
        exit({:shutdown, 1})
    end
  end

  # Claims a `ready/<slug>.md` pitch by an atomic same-filesystem rename into
  # `building/<slug>.md`, BEFORE the loop runs — the moment of possession.
  # A `File.rename/2` race loser gets `{:error, :enoent}` (the source is
  # already gone) and refuses loud rather than silently proceeding to build
  # a pitch someone else is already building. Any other rename error
  # propagates uncaught (a genuine anomaly, never swallowed).
  #
  # Deliberately NOT called from `run_loop_catching_infra_abort/1`'s rescue
  # arm — an infra abort must leave the pitch in `building/`, mirroring
  # `LoopQueueDrain.handle_infra_abort/4`'s existing "pitch remains
  # untouched" posture (the box is broken; nothing about the pitch was
  # wrong).
  @doc false
  @spec claim_pitch!({:file, String.t()} | :literal, String.t()) ::
          {:file, String.t()} | :literal
  def claim_pitch!(:literal, _cwd), do: :literal

  def claim_pitch!({:file, abs}, cwd) do
    ready_dir = Path.join([cwd, "codegen", "pitches", "ready"])
    building_dir = Path.join([cwd, "codegen", "pitches", "building"])
    name = Path.basename(abs)
    src_in_ready = Path.join(ready_dir, name)

    if Path.expand(abs) == Path.expand(src_in_ready) do
      File.mkdir_p!(building_dir)
      dst = Path.join(building_dir, name)

      case File.rename(src_in_ready, dst) do
        :ok ->
          {:file, dst}

        {:error, :enoent} ->
          slug = Path.basename(abs, ".md")
          Mix.shell().error("codegen.loop: pitch already claimed (building/) — #{slug}")
          exit({:shutdown, 2})

        {:error, reason} ->
          raise "codegen.loop: claim_pitch! failed to rename #{src_in_ready} -> #{dst}: " <>
                  "#{inspect(reason)}"
      end
    else
      {:file, abs}
    end
  end

  # Restores a claimed pitch from building/ back to ready/ on a diff-failure
  # exit — the pitch's work did NOT land, so it must remain dispatchable to
  # the next builder. A no-op for a source that was never claimed (:literal,
  # or a file outside building/).
  @doc false
  @spec restore_claim({:file, String.t()} | :literal, String.t()) :: :ok
  def restore_claim(:literal, _cwd), do: :ok

  def restore_claim({:file, abs}, cwd) do
    building_dir = Path.join([cwd, "codegen", "pitches", "building"])
    ready_dir = Path.join([cwd, "codegen", "pitches", "ready"])
    name = Path.basename(abs)
    src_in_building = Path.join(building_dir, name)

    if Path.expand(abs) == Path.expand(src_in_building) and File.exists?(src_in_building) do
      File.mkdir_p!(ready_dir)
      File.rename!(src_in_building, Path.join(ready_dir, name))
      :ok
    else
      :ok
    end
  end

  # Runs `run_fn` and converts a raised `CodegenTestHarness.InfraAbort` into
  # process exit code `@infra_abort_exit_code` (3) — the signal
  # `LoopQueueDrain` needs to tell "the box is broken" apart from "this
  # pitch's diff didn't pass" (see module doc). Extracted as its own
  # function (rather than inlined in `run/1`) so it is directly testable
  # without exercising OptionParser/git/telemetry plumbing: a test can pass
  # a `run_fn` that raises `InfraAbort` and assert the resulting exit
  # without needing a real cwd/pitch/harness.
  @doc false
  @spec run_loop_catching_infra_abort((-> :ok | {:error, String.t()})) ::
          :ok | {:error, String.t()}
  def run_loop_catching_infra_abort(run_fn) do
    run_fn.()
  rescue
    e in InfraAbort ->
      Mix.shell().error("codegen.loop: #{e.message}")
      exit({:shutdown, @infra_abort_exit_code})
  end

  @doc false
  def emit_loop_telemetry(result) do
    t = OrchestrationLoop.get_telemetry()

    subtype = if result == :ok, do: "success", else: "error"

    per_role =
      Map.new(t.per_role, fn {role, entries} ->
        summed =
          Enum.reduce(
            entries,
            %{
              cost_usd: 0.0,
              input_tokens: 0,
              output_tokens: 0,
              num_turns: 0,
              cache_read_tokens: 0,
              cache_creation_tokens: 0
            },
            fn e, acc ->
              %{
                cost_usd: acc.cost_usd + e.cost_usd,
                input_tokens: acc.input_tokens + e.input_tokens,
                output_tokens: acc.output_tokens + e.output_tokens,
                num_turns: acc.num_turns + e.num_turns,
                cache_read_tokens: acc.cache_read_tokens + e.cache_read_tokens,
                cache_creation_tokens: acc.cache_creation_tokens + e.cache_creation_tokens
              }
            end
          )

        # Additive: each entry's `dispatch` (harness/model/effort actually
        # requested for that invocation — see
        # `OrchestrationLoop.accumulate_telemetry/3`) is projected here as an
        # ORDERED list, one per call, in the order they were made. Every
        # existing key above (cost_usd, tokens, calls, ...) is untouched —
        # this is a new key on the same map, never a replacement.
        dispatches = Enum.map(entries, & &1.dispatch)

        {role, summed |> Map.put(:calls, length(entries)) |> Map.put(:dispatches, dispatches)}
      end)

    line =
      Jason.encode!(%{
        "type" => "result",
        "subtype" => subtype,
        "engine" => "elixir_loop",
        "num_turns" => t.num_turns,
        "total_cost_usd" => t.cost_usd,
        "terminal_reason" => if(result == :ok, do: "loop_committed", else: "loop_failed"),
        "role_calls" => t.role_calls,
        "usage" => %{
          "input_tokens" => t.input_tokens,
          "output_tokens" => t.output_tokens,
          "cache_read_input_tokens" => t.cache_read_tokens,
          "cache_creation_input_tokens" => t.cache_creation_tokens
        },
        "per_role" => per_role
      })

    IO.puts(line)
  end

  @doc false
  @spec resolve_pitch(String.t(), String.t()) :: String.t()
  def resolve_pitch("@" <> path, cwd) do
    abs = Path.expand(path, cwd)

    unless File.exists?(abs) do
      Mix.shell().error("codegen.loop: pitch file not found at #{abs}")
      exit({:shutdown, 2})
    end

    abs
    |> File.read!()
    |> LoopQueue.strip_frontmatter()
  end

  def resolve_pitch(literal, cwd) do
    abs = Path.expand(literal, cwd)

    if File.exists?(abs) do
      abs
      |> File.read!()
      |> LoopQueue.strip_frontmatter()
    else
      literal
    end
  end

  @doc false
  @spec resolve_pitch_source(String.t(), String.t()) :: {:file, String.t()} | :literal
  def resolve_pitch_source("@" <> path, cwd) do
    abs = Path.expand(path, cwd)
    if File.exists?(abs), do: {:file, abs}, else: :literal
  end

  def resolve_pitch_source(literal, cwd) do
    abs = Path.expand(literal, cwd)
    if File.exists?(abs), do: {:file, abs}, else: :literal
  end

  # Extracts the sha string from git_head/1's {:ok, sha} | :unborn shape for
  # threading into maybe_ship_pitch/4 — :unborn (non-git cwd) becomes nil,
  # which is record_ship/4's own fail-open carve-out.
  @spec before_sha({:ok, String.t()} | :unborn) :: String.t() | nil
  defp before_sha({:ok, sha}), do: sha
  defp before_sha(:unborn), do: nil

  @doc false
  @spec maybe_ship_pitch(
          {:file, String.t()} | :literal,
          String.t(),
          String.t() | nil,
          String.t() | nil
        ) :: :ok
  def maybe_ship_pitch(source, cwd, before_sha \\ nil, after_sha \\ nil)

  def maybe_ship_pitch(:literal, _cwd, _before_sha, _after_sha), do: :ok

  def maybe_ship_pitch({:file, abs}, cwd, before_sha, after_sha) do
    ready_dir = Path.join([cwd, "codegen", "pitches", "ready"])
    building_dir = Path.join([cwd, "codegen", "pitches", "building"])
    name = Path.basename(abs)
    src_in_ready = Path.join(ready_dir, name)
    src_in_building = Path.join(building_dir, name)

    # A claimed pitch's source is building/<name> (the normal path, post
    # claim_pitch!); a still-ready/<name> source is the legacy/no-claim
    # shape (e.g. a test driving maybe_ship_pitch/4 directly). Either is a
    # valid ship source.
    src =
      cond do
        Path.expand(abs) == Path.expand(src_in_building) -> src_in_building
        Path.expand(abs) == Path.expand(src_in_ready) -> src_in_ready
        true -> nil
      end

    if src do
      shipped_dir = Path.join([cwd, "codegen", "pitches", "shipped"])
      slug = Path.basename(abs, ".md")

      ship_ready_pitch(
        src,
        Path.join(shipped_dir, name),
        cwd,
        slug,
        before_sha,
        after_sha
      )
    else
      :ok
    end
  end

  defp missing_flag!(name) do
    Mix.shell().error("codegen.loop: #{name} is required")
    exit({:shutdown, 2})
  end

  # Gate: `verify_commit_landed/2` below.

  # Ship-gate floor for the SOLO path (the drain's twin floor already lives
  # in `LoopQueueDrain.handle_exit_zero/8`): `OrchestrationLoop.run/1` can
  # return a bare `:ok` with no work having actually landed — with the
  # turn-0 realized-check preflight removed, the only remaining source of
  # that would be a defect in the role chain itself, but this floor exists
  # so such a defect fails LOUD (refuse the ship) instead of silently
  # shipping an empty cycle. Requires HEAD to have moved AND the prior HEAD
  # to be an ancestor of the new one (non-orphaning — rules out a rebase
  # that discarded history rather than adding to it). Fails OPEN on a
  # non-git cwd / unborn HEAD (mirrors `assert_clean_tree!/1`'s own
  # fail-open posture for the same non-git case) — synthetic test cwds and
  # the codegen self-build's own root are the intended beneficiaries.
  @doc false
  @spec git_head(String.t()) :: {:ok, String.t()} | :unborn
  def git_head(cwd) do
    case System.cmd("git", ["-C", cwd, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {_out, _nonzero} -> :unborn
    end
  end

  # All three success arms return the SAME shape, {:ok, sha | nil} — nil is
  # the non-git/unborn carve-out (mirrors assert_clean_tree!/1's fail-open
  # posture) and is exactly the value maybe_ship_pitch/4 threads into
  # LoopQueue.record_ship/4's own fail-open clause. One value, one meaning,
  # rather than a second code path that could drift from it.
  @doc false
  @spec verify_commit_landed({:ok, String.t()} | :unborn, String.t()) ::
          {:ok, String.t() | nil} | {:error, String.t()}
  def verify_commit_landed(:unborn, _cwd), do: {:ok, nil}

  def verify_commit_landed({:ok, before_sha}, cwd) do
    case git_head(cwd) do
      :unborn ->
        {:ok, nil}

      {:ok, after_sha} ->
        cond do
          after_sha == before_sha ->
            {:error, "HEAD did not advance (no commit this cycle)"}

          not ancestor?(cwd, before_sha, after_sha) ->
            {:error,
             "HEAD advanced but #{before_sha} is not an ancestor of #{after_sha} (history rewritten, not extended)"}

          true ->
            {:ok, after_sha}
        end
    end
  end

  defp ancestor?(cwd, ancestor_sha, descendant_sha) do
    case System.cmd(
           "git",
           ["-C", cwd, "merge-base", "--is-ancestor", ancestor_sha, descendant_sha],
           stderr_to_stdout: true
         ) do
      {_out, 0} -> true
      {_out, _nonzero} -> false
    end
  end

  # Retire follows git truth: on a VERIFIED landing (the caller already
  # proved HEAD advanced + ancestor-extended via verify_commit_landed/2),
  # the pitch leaves ready/or building/ UNCONDITIONALLY — record_ship +
  # rename run FIRST. The clean-tree check runs SECOND, as a loud non-fatal
  # signal (exit @dirty_tree_exit_code) rather than a gate that could strand
  # already-landed work back in a dispatchable directory. See
  # codegen/pitches/shipped/a-landed-pitch-cannot-be-handed-out-again.md —
  # a pitch whose work landed must never be handed to a builder again, and
  # blocking the retire on tree cleanliness never protected those dirty
  # files anyway (they stay dirty either way); it only decided whether the
  # landed pitch remains dispatchable.
  defp ship_ready_pitch(src, dst, cwd, slug, before_sha, after_sha) do
    cond do
      not File.exists?(src) and File.exists?(dst) ->
        :ok

      true ->
        # Frontmatter, then the mv — see LoopQueue.record_ship/4
        # moduledoc for why this order is load-bearing (a stranded
        # shipped_sha: on a still-ready/ pitch is read by the NEXT
        # build's prompt as "already shipped").
        LoopQueue.record_ship(cwd, slug, before_sha, after_sha)
        File.mkdir_p!(Path.dirname(dst))
        File.rename!(src, dst)
        warn_dirty_after_retire(cwd)
        :ok
    end
  end

  # Loud, non-fatal-to-the-ship signal: the pitch already left ready/
  # (unconditionally, above) — a dirty tree here can no longer strand it.
  # Prints the dirty status and exits @dirty_tree_exit_code so the drain
  # (LoopQueueDrain) can classify this as shipped-with-warning rather than
  # a failed pitch to requeue. Fails open (returns normally, no exit) on a
  # non-git cwd — mirrors the removed assert_clean_tree!/1's own posture.
  defp warn_dirty_after_retire(cwd) do
    case System.cmd("git", ["-C", cwd, "rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {_out, 0} ->
        {status, _} =
          System.cmd("git", ["-C", cwd, "status", "--porcelain"], stderr_to_stdout: true)

        if String.trim(status) != "" do
          Mix.shell().error(
            "codegen.loop: COMMITTED and RETIRED — working tree not clean:\n#{status}"
          )

          exit({:shutdown, @dirty_tree_exit_code})
        end

        :ok

      # not a git repo / git unavailable — fail open (mirrors legacy clean-tree-before-ship.sh)
      {_out, _nonzero} ->
        :ok
    end
  end
end
