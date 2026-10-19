defmodule Kogen.Build do
  @moduledoc """
  `kogen intent build <slug>` (chapters 03-07): start checks, then the
  builder conversation with `shell`, `read_file`, `write_file`, `finish` and `report_blocker`; after each round the
  fixers and a verification pass; a green pass goes to independent review/fix, followed by
  external verification of repairs; an approved, verified, still identical candidate is committed. No time or token limit: a Build ends with a commit, an
  integrity stop, a provider failure, context exhaustion, an invalid/unresolved review or an interrupt.
  """
  alias Kogen.{
    Bridge,
    ChatGPT,
    Checks,
    Config,
    Error,
    Git,
    Intent,
    Lock,
    Readiness,
    Review,
    Run,
    Shape,
    Snapshot,
    Tools,
    Usage
  }

  def run(project, slug) do
    root = Git.root!(project)
    config = Config.load!(root)

    start =
      Git.head(root) ||
        Error.raise!("environment", "no_head", "#{root} has no commits; run kogen init", 3)

    if op = Git.operation_in_progress(root) do
      Error.raise!(
        "environment",
        "git_operation_in_progress",
        "a #{op} is in progress; finish or abort it first",
        3
      )
    end

    lock = lock!(root)

    try do
      checked(root, slug, config, start)
    after
      Lock.release(lock)
    end
  end

  def resume(project, id) do
    Process.delete(:kogen_build)
    root = Git.root!(project)
    lock = lock!(root)

    try do
      resume_locked(root, id)
    after
      Lock.release(lock)
    end
  end

  defp refuse!(id, reason, kind \\ "resume_refused") do
    Error.raise!(
      "candidate",
      kind,
      "Build #{id}: #{reason}; inspect the checkpoint and checkout, correct drift or obtain fresh approval for a new Build",
      1
    )
  end

  defp resume_locked(root, id) do
    unless Regex.match?(~r/^[a-f0-9]{8}$/, id),
      do: refuse!(id, "unknown checkpoint", "resume_unsupported")

    path = Path.join(root, ".kogen/local/runs/#{id}/checkpoint.json")

    bytes =
      case File.read(path) do
        {:ok, bytes} -> bytes
        _ -> refuse!(id, "absent or legacy checkpoint", "resume_unsupported")
      end

    {doc, b} =
      case Run.decode_checkpoint(bytes) do
        {:ok, doc, b} -> {doc, b}
        {:error, why} -> refuse!(id, why)
      end

    unless b.root == root and doc["identity"] == identity(root),
      do: refuse!(id, "another checkout identity")

    git_index =
      Path.join(Git.ok!(root, ["rev-parse", "--absolute-git-dir"]) |> String.trim(), "index")

    unless b.run.id == id and b.run.dir == Path.dirname(path) and
             b.run.log == Path.join(b.run.dir, "log.jsonl") and b.git_index == git_index,
           do: refuse!(id, "checkpoint run/index paths changed")

    if b.continuation.stage == :landed and Git.head(root) == b.continuation.commit do
      commit = b.continuation.commit

      unless String.trim(Git.ok!(root, ["rev-parse", "#{commit}^"])) == b.start and
               String.trim(Git.ok!(root, ["rev-parse", "#{commit}^{tree}"])) == b.last_pass.tree and
               b.last_review.tree == b.last_pass.tree and b.last_pass.green,
             do: refuse!(id, "already-landed commit provenance changed")

      Bridge.puts("Build #{id} already landed #{b.continuation.commit}")
      0
    else
      unless Git.head(root) == b.start,
        do: refuse!(id, "HEAD moved or uncertain commit; inspect git log")

      if b.continuation.stage in [:tool, :commit, :startup],
        do:
          refuse!(
            id,
            "uncertain #{b.continuation.stage} boundary; inspect effects before starting a freshly approved Build"
          )

      if b.blocker,
        do: refuse!(id, "protected-contract blocker requires correction and fresh approval")

      unless File.read(Intent.approval_path(root, b.slug)) ==
               {:ok, Base.decode64!(doc["approval"])},
             do: refuse!(id, "approval changed")

      for p <- b.baseline do
        unless file_digest(root, p) == b.baseline_digests[p],
          do: refuse!(id, "baseline changed: #{p}")
      end

      unless Config.load!(root) == b.config and
               Intent.baseline(root, b.slug, b.config) == b.baseline,
             do: refuse!(id, "baseline/configuration changed")

      saved_index = Base.decode64!(doc["index"])

      unless File.read(b.git_index) == {:ok, saved_index},
        do: refuse!(id, "index/staged custody changed")

      original_index = Path.join(b.run.dir, "index-at-start")

      unless File.read(original_index) == {:ok, saved_index},
        do: refuse!(id, "original index backup missing or damaged: #{original_index}")

      candidate = Snapshot.tree(root, b.start, [])

      unless candidate == doc["candidate"] do
        paths = Snapshot.changed(root, doc["candidate"], candidate)

        refuse!(
          id,
          "candidate contents/modes or unrelated paths changed: #{Enum.join(paths, ", ")}"
        )
      end

      run = Run.start(root)
      File.write!(Path.join(run.dir, "index-at-start"), saved_index)

      b = %{
        b
        | run: run,
          parent: id,
          root_run: b.root_run || id,
          t0: System.monotonic_time(:millisecond),
          attempt_usage: Usage.zero()
      }

      Bridge.puts("resuming Build #{id} as #{run.id} (root #{b.root_run})")
      Run.log(run, %{"event" => "resume", "parent" => id, "root" => b.root_run})
      Process.put(:kogen_build, b)
      save(b, b.continuation)
      build_started(b)

      try do
        ChatGPT.require_login!()

        case b.continuation.stage do
          :builder ->
            builder_turn(b, b.continuation.input)

          :builder_verify ->
            c = b.continuation
            {b, feedback} = round_end(b)

            output =
              if c.finish,
                do: Shape.output(c.finish, feedback),
                else: %{"role" => "user", "content" => feedback}

            loop(b, c.input ++ [output])

          stage when stage in [:review, :review_verify] ->
            {:approve, b, pass, review} = Review.resume(b, &verify/1)
            commit(b, pass, review)
        end
      rescue
        e in Error -> stopped(Process.get(:kogen_build), e)
      catch
        {:cancel, sig} -> interrupted(Process.get(:kogen_build), sig)
        {:failed, b, e} -> stopped(b, e)
        {:landed, code} -> code
      end
    end
  end

  defp identity(root) do
    stat = File.stat!(root)
    "#{root}:#{stat.major_device}:#{stat.inode}"
  end

  @doc false
  def save(b, continuation) do
    b = track(%{b | continuation: continuation})

    Run.checkpoint(b.run, %{
      "version" => 2,
      "identity" => identity(b.root),
      "candidate" => Snapshot.tree(b.root, b.start, []),
      "index" => Base.encode64(File.read!(b.git_index)),
      "approval" => b.approval_bytes,
      "state" => Base.encode64(:erlang.term_to_binary(b))
    })

    b
  end

  # ---- Start checks (AUT-3..5, GIT-1) ----

  @doc false
  def lock!(root) do
    path = Path.join(root, ".kogen/local/build.lock")

    case Lock.acquire(path) do
      :ok ->
        path

      {:removed_stale, _pid} ->
        Bridge.progress("kogen: removed the lock of a Build that is no longer running")
        path

      {:held, pid} ->
        Error.raise!(
          "environment",
          "build_running",
          "a Build is running in this repository (pid #{pid})",
          3
        )
    end
  end

  @doc false
  def clean_paths!(root, slug) do
    # GIT-1: only this Intent's folder and acceptance files, and other Intents' own folders, may
    # be uncommitted; the other folders stay out of the candidate and the commit (VER-10).
    changed = Git.changed_paths(root)

    other_paths =
      Enum.filter(
        changed,
        &(String.starts_with?(&1, ".kogen/intents/") and
            not String.starts_with?(&1, Intent.dir(slug) <> "/"))
      )

    own = Intent.read(root, slug).acceptance || []

    dirty =
      Enum.reject(
        changed,
        &(&1 in other_paths or &1 in own or String.starts_with?(&1, Intent.dir(slug) <> "/"))
      )

    if dirty != [] do
      Error.raise!(
        "environment",
        "dirty_tree",
        "#{length(dirty)} changed path(s) are not part of an Intent; commit, stash or discard them first",
        5,
        Enum.take(dirty, 20)
      )
    end

    # Exclude the entire other Intent, including files created after this check.
    other_paths
    |> Enum.map(&(&1 |> Path.split() |> Enum.take(3) |> Path.join()))
    |> Enum.uniq()
  end

  defp checked(root, slug, config, start) do
    Intent.exists!(root, slug)

    approval =
      Intent.approval(root, slug) ||
        Error.raise!(
          "intent",
          "not_approved",
          "#{slug} is not approved; review it with kogen intent approve #{slug}",
          5
        )

    baseline = Intent.baseline(root, slug, config)
    sha = Intent.hash(root, baseline)

    if sha != approval["sha256"] do
      Error.raise!(
        "intent",
        "changed_since_approval",
        "#{slug} changed after approval and is now #{String.slice(sha, 0, 8)}; review it again with kogen intent approve #{slug}",
        1
      )
    end

    excluded = clean_paths!(root, slug)

    intent = Intent.read(root, slug)
    model = Intent.model(intent)
    ChatGPT.require_login!()
    Readiness.tools!(root, config)
    if model != :none, do: Checks.require_quint!()
    run = Run.start(root)
    # GIT-8: a Build that does not commit leaves the index as it found it.
    git_index =
      Path.join(Git.ok!(root, ["rev-parse", "--absolute-git-dir"]) |> String.trim(), "index")

    File.cp!(git_index, Path.join(run.dir, "index-at-start"))
    digests = Map.new(baseline, &{&1, file_digest(root, &1)})

    b = %{
      root: root,
      slug: slug,
      config: config,
      intent: intent,
      model: model,
      start: start,
      baseline: baseline,
      excluded: excluded,
      run: run,
      baseline_digests: digests,
      git_index: git_index,
      start_tree: Snapshot.tree(root, start, excluded),
      phase: :startup,
      t0: System.monotonic_time(:millisecond),
      usage: Usage.zero(),
      round: 0,
      pass: 0,
      review: 0,
      repairs: 0,
      last_pass: nil,
      last_review: nil,
      blocker: nil,
      continuation: %{stage: :startup},
      approval_bytes: Base.encode64(File.read!(Intent.approval_path(root, slug))),
      parent: nil,
      root_run: nil,
      model_active_ms: 0,
      unknown_requests: 0,
      attempt_usage: Usage.zero()
    }

    build_started(b)

    Run.log(run, %{"event" => "start", "slug" => slug, "start_head" => start, "approved" => sha})
    save(b, b.continuation)

    try do
      commit_msg_hook!(root, intent.title, slug)
      baseline_intact!(b)
      Readiness.setup!(root, config, run)
      Readiness.tools!(root, config, true)
      baseline_intact!(b)
      already_failing!(root, config, run)
      Bridge.puts("building #{slug}")
      start_builder(track(%{b | phase: :building}))
    rescue
      e in Error -> stopped(Process.get(:kogen_build), e)
    catch
      {:cancel, sig} -> interrupted(Process.get(:kogen_build), sig)
      {:failed, b, e} -> stopped(b, e)
      {:landed, code} -> code
    end
  end

  defp build_started(b) do
    Bridge.send_msg(%{
      "type" => "build_started",
      "root" => b.root,
      "start_head" => b.start,
      "run_log" => b.run.log
    })
  end

  # AUT-5: the user's commit-msg hook judges the commit message before any model time is spent.
  defp commit_msg_hook!(root, title, slug) do
    msg = Kogen.tmp_path("kogen-commit-msg")
    File.write!(msg, commit_message(title, slug))

    r =
      try do
        Bridge.exec(
          "git hook run --ignore-missing commit-msg -- #{Kogen.Init.shell_quote(msg)}",
          root
        )
      after
        File.rm(msg)
      end

    if r.status != 0 do
      Error.raise!(
        "environment",
        "commit_rejected",
        "the commit-msg hook rejects this Intent's commit message (status=#{r.status}); change the Intent's title or the hook, then approve again",
        3,
        String.split(Checks.tail(r.output, 20), "\n")
      )
    end
  end

  defp commit_message(title, slug), do: "#{title}\n\nKogen-Intent: #{slug}\n"

  # AUT-5: a check that fails before any change could never turn green; refuse instead of
  # repairing without end.
  defp already_failing!(root, config, run) do
    for {name, cmd} <- config.checks do
      Bridge.progress("kogen: checking #{name} before the Build changes anything")

      Run.log(run, %{
        "event" => "command",
        "name" => name,
        "command" => cmd,
        "before_change" => true
      })

      r = Bridge.exec(cmd, root)

      Run.log(run, %{
        "event" => "command_result",
        "name" => name,
        "status" => r.status,
        "output" => Run.cap(r.output)
      })

      if r.status != 0 do
        Error.raise!(
          "environment",
          "check_failing",
          "check #{name} fails before the Build changes anything (status=#{r.status}); fix it or remove it from commands.checks",
          3,
          String.split(Checks.tail(r.output, 20), "\n")
        )
      end
    end
  end

  # ---- Build (LOOP-1..7) ----

  defp start_builder(b), do: loop(b, [%{"role" => "user", "content" => context(b)}])

  # The latest Build state, for the report of a Build that stops on an error or an interrupt.
  @doc false
  def track(b) do
    old = Process.get(:kogen_build)

    b =
      if old && old.run.id == b.run.id do
        Map.merge(b, Map.take(old, [:model_active_ms, :unknown_requests, :attempt_usage, :usage]))
      else
        b
      end

    Process.put(:kogen_build, b)
    b
  end

  defp loop(b, input) do
    b = track(%{b | round: b.round + 1})
    Bridge.progress("kogen: building (round #{b.round})")
    builder_turn(b, input)
  end

  defp builder_turn(b, input) do
    b = save(b, %{stage: :builder, input: input})
    role = b.config.models["build"]

    resp =
      request(
        b,
        "build",
        role,
        builder_instructions(),
        input,
        Tools.defs(~w(shell read_file write_file finish report_blocker))
      )

    b = track(b)
    calls = for %{"type" => "function_call"} = c <- resp.items, do: c
    input = input ++ (Enum.map(resp.items, &Shape.replay_item/1) |> Enum.reject(&is_nil/1))
    ctx = %{root: b.root, protected: b.baseline, tools: ~w(shell read_file write_file)}

    {outputs, finish} =
      Enum.reduce(calls, {[], nil}, fn call, {outs, finish} ->
        Bridge.check_cancel()
        args = Shape.decode(call)

        save(b, %{stage: :tool, owner: :builder, input: input ++ outs})

        result =
          case call["name"] do
            "finish" -> :finish
            "report_blocker" -> report_blocker(b, args, call)
            name -> name |> Tools.run(args, ctx) |> Tools.cut()
          end

        Run.log(b.run, %{
          "event" => "tool_call",
          "call_id" => call["call_id"],
          "name" => call["name"],
          "arguments" => Run.cap(call["arguments"] || ""),
          "result" => if(result == :finish, do: "finish", else: Run.cap(result))
        })

        save(b, %{
          stage: :tool,
          owner: :builder,
          input: input ++ outs,
          completed: %{call: call, result: result}
        })

        if call["name"] == "shell", do: baseline_intact!(b)

        case result do
          :finish -> {outs, call}
          text -> {outs ++ [Shape.output(call, text)], finish}
        end
      end)

    if finish != nil or calls == [] do
      b = save(b, %{stage: :builder_verify, input: input ++ outputs, finish: finish})
      {b, feedback} = round_end(b)
      input = input ++ outputs

      input =
        if finish,
          do: input ++ [Shape.output(finish, feedback)],
          else: input ++ [%{"role" => "user", "content" => feedback}]

      loop(b, input)
    else
      builder_turn(b, input ++ outputs)
    end
  end

  defp report_blocker(b, args, call) do
    paths = args["paths"]

    valid =
      Enum.sort(Map.keys(args)) == ~w(evidence paths reason) and is_list(paths) and paths != [] and
        Enum.all?(paths, &(is_binary(&1) and &1 in b.baseline)) and
        Enum.uniq(paths) == paths and
        Enum.all?([args["reason"], args["evidence"]], &(is_binary(&1) and String.trim(&1) != ""))

    if valid do
      baseline_intact!(b)
      head_intact!(b)
      blocker = Map.put(args, "classification", "BUILDER-REPORTED")
      b = track(%{b | blocker: blocker})

      Run.log(b.run, %{
        "event" => "tool_call",
        "call_id" => call["call_id"],
        "name" => "report_blocker",
        "arguments" => Run.cap(call["arguments"] || ""),
        "result" => "BUILDER-REPORTED build_blocked"
      })

      Run.log(b.run, %{"event" => "builder_blocker", "blocker" => blocker})

      throw(
        {:failed, b,
         %Error{
           class: "candidate",
           reason: "build_blocked",
           detail:
             "BUILDER-REPORTED protected-baseline contradiction; edits are left in place; this report is not independently proven",
           lines: [
             "paths: #{Enum.join(paths, ", ")}",
             "reason: #{Tools.cut(args["reason"])}",
             "evidence: #{Tools.cut(args["evidence"])}"
           ],
           exit: 1
         }}
      )
    else
      "invalid blocker: supply exactly nonempty unique current protected paths, reason and observed evidence strings; no write permission is granted; continue ordinary implementation repairs"
    end
  end

  # Fixers once, then passes and reviews until the builder has work again or the Build lands.
  defp round_end(b) do
    for {cmd, i} <- Enum.with_index(b.config.fix, 1) do
      Run.log(b.run, %{"event" => "command", "name" => "fix-#{i}", "command" => cmd})
      r = Bridge.exec(cmd, b.root)

      Run.log(b.run, %{
        "event" => "command_result",
        "name" => "fix-#{i}",
        "status" => r.status,
        "output" => Run.cap(r.output)
      })

      baseline_intact!(b)
    end

    verify_and_review(b)
  end

  defp verify_and_review(b) do
    {b, pass} = verify(b)

    if not pass.green do
      {%{b | repairs: b.repairs + 1}, pass_feedback(b, pass)}
    else
      {:approve, b, final_pass, review} = Review.run(b, pass, &verify/1)
      commit(track(b), final_pass, review)
    end
  end

  # ---- Verification (VER-1..10) ----

  defp verify(b) do
    b = %{b | pass: b.pass + 1}
    n = b.pass
    Bridge.progress("kogen: verifying (pass #{n})")
    before = Snapshot.tree(b.root, b.start, b.excluded)
    report = Path.join(b.run.dir, "acceptance-#{n}.ndjson")
    scratch = Kogen.tmp_path("kogen-verify")

    {acceptance, model, checks, scratch_moved} =
      try do
        input = Snapshot.materialize(b.root, before, scratch)
        File.mkdir_p!(Path.join(scratch, ".kogen/local"))
        setup = clean_setup(b, scratch)

        {acceptance, model, checks} =
          if setup == [] do
            acceptance =
              Checks.acceptance(scratch, b.intent, b.config.acceptance_run, report, run: b.run)

            model =
              case b.model do
                :none -> :none
                m -> Checks.model(scratch, m, run: b.run)
              end

            checks =
              for {name, cmd} <- b.config.checks, do: verification_command(b, scratch, name, cmd)

            {acceptance, model, checks}
          else
            {%{problems: [], status: 0, scenarios: [], passed: 0}, :none, setup}
          end

        {acceptance, model, checks, Snapshot.mutations(scratch, input)}
      after
        File.rm_rf!(scratch)
      end

    baseline_intact!(b)
    after_tree = Snapshot.tree(b.root, b.start, b.excluded)
    moved = Enum.uniq(scratch_moved ++ Snapshot.changed(b.root, before, after_tree))

    failing =
      if(acceptance.problems == [], do: [], else: ["acceptance"]) ++
        if(match?({:failed, _}, model), do: ["model"], else: []) ++
        for(c <- checks, c.status != 0, do: c.name)

    pass = %{
      n: n,
      tree: before,
      clean: true,
      acceptance: acceptance,
      model: model,
      checks: checks,
      moved: moved,
      failing: failing,
      green: failing == [] and moved == []
    }

    Bridge.progress(
      "kogen: pass #{n}: " <>
        cond do
          pass.green -> "all checks passed"
          failing != [] -> "#{Enum.join(failing, ", ")} failed"
          true -> "files changed while the checks ran: #{Enum.join(moved, ", ")}"
        end
    )

    Run.log(b.run, %{
      "event" => "pass",
      "pass" => n,
      "green" => pass.green,
      "failing" => failing,
      "files_changed_while_checks_ran" => moved
    })

    {track(%{b | last_pass: pass}), pass}
  end

  defp verification_command(b, root, name, cmd) do
    Run.log(b.run, %{"event" => "command", "name" => name, "command" => cmd, "cwd" => root})
    r = Bridge.exec(cmd, root)

    Run.log(b.run, %{
      "event" => "command_result",
      "name" => name,
      "status" => r.status,
      "output" => Run.cap(r.output)
    })

    %{name: name, command: cmd, status: r.status, output: r.output}
  end

  defp clean_setup(b, root) do
    Enum.reduce_while(Enum.with_index(b.config.setup, 1), [], fn {cmd, i}, _ ->
      Bridge.progress("kogen: running setup-#{i}: #{cmd}")
      Kogen.ShapeEvidence.count("setup")
      r = verification_command(b, root, "setup-#{i}", cmd)
      if r.status == 0, do: {:cont, []}, else: {:halt, [r]}
    end)
  end

  @doc false
  def pass_feedback(b, pass, completion \\ "finish") do
    acceptance =
      if pass.acceptance.problems == [],
        do: [],
        else: [
          "acceptance (#{b.config.acceptance_run}): failed, exit status #{pass.acceptance.status}"
          | Enum.map(pass.acceptance.problems, &indent/1)
        ]

    model =
      case pass.model do
        {:failed, problems} -> ["model: failed" | Enum.map(problems, &indent/1)]
        _ -> []
      end

    checks =
      for c <- pass.checks, c.status != 0 do
        "check #{c.name} (#{c.command}): failed, exit status #{c.status}\n" <>
          indent(Checks.tail(c.output, 60))
      end

    moved =
      if pass.moved == [],
        do: [],
        else: ["files changed while checks ran: #{Enum.join(pass.moved, ", ")}"]

    Enum.join(
      [
        "Verification pass #{pass.n} is not green. Fix the implementation (the approved acceptance files cannot change), then call #{completion} again."
      ] ++
        acceptance ++ model ++ checks ++ moved,
      "\n"
    )
  end

  defp indent(text), do: text |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1))

  # VER-8: after every shell call, fixer and pass, the baseline must be as approved: the same
  # files (a new file in the Intent's folder or matching `protect` joins it) with the same bytes.
  @doc false
  def baseline_intact!(b) do
    now = Intent.baseline(b.root, b.slug, b.config)
    added = now -- b.baseline

    changed =
      Enum.filter(b.baseline, &(file_digest(b.root, &1) != Map.fetch!(b.baseline_digests, &1))) ++
        added

    if changed != [] do
      detail =
        "the Build changed acceptance files: #{Enum.join(changed, ", ")}; nothing was committed; review the files, then approve again or discard the edits"

      throw(
        {:failed, b,
         %Error{class: "candidate", reason: "baseline_changed", detail: detail, exit: 1}}
      )
    end
  end

  defp file_digest(root, p) do
    case File.read(Path.join(root, p)) do
      {:ok, bytes} -> :crypto.hash(:sha256, bytes)
      _ -> :missing
    end
  end

  defp head_intact!(b) do
    head = Git.head(b.root)

    if head != b.start do
      current_head = if head, do: String.slice(head, 0, 8), else: "(missing)"

      throw(
        {:failed, b,
         %Error{
           class: "candidate",
           reason: "head_moved",
           detail:
             "HEAD moved from #{String.slice(b.start, 0, 8)} to #{current_head} during the Build; nothing was committed",
           exit: 1
         }}
      )
    end
  end

  # ---- Commit (GIT-3..8) ----

  defp commit(b, pass, review) do
    Bridge.progress("kogen: committing")
    Bridge.check_cancel()
    baseline_intact!(b)
    head_intact!(b)

    if not (pass.green and pass.clean and review.tree == pass.tree) or
         Snapshot.tree(b.root, b.start, b.excluded) != pass.tree do
      # Something changed after the reviewed pass: verify and review again.
      verify_and_review(b)
    else
      b = save(b, %{stage: :commit, tree: pass.tree})
      Git.ok!(b.root, ["read-tree", pass.tree])
      msg = Path.join(b.run.dir, "commit-message.txt")
      File.write!(msg, commit_message(b.intent.title, b.slug))
      Run.log(b.run, %{"event" => "commit", "tree" => pass.tree})
      Process.put(:kogen_committing, b)

      r =
        Bridge.exec("git commit -q -F #{Kogen.Init.shell_quote(msg)}", b.root,
          finish_on_cancel: true
        )

      # An interrupt that arrived while git commit ran is handled before the commit is accepted.
      Bridge.check_cancel()

      if r.status != 0 do
        lines = r.output |> String.trim() |> String.split("\n")

        throw(
          {:failed, b,
           %Error{
             class: "environment",
             reason: "commit_failed",
             detail:
               "git commit failed (status #{r.status}); the verified changes are left uncommitted",
             exit: 3,
             lines: lines
           }}
        )
      end

      landed(b, pass, review)
    end
  end

  defp landed(b, pass, review) do
    new = Git.head(b.root)
    tree = b.root |> Git.ok!(["rev-parse", "#{new}^{tree}"]) |> String.trim()
    parent = b.root |> Git.ok!(["rev-parse", "#{new}^"]) |> String.trim()
    # GIT-6: signed when the user's configuration signs.
    signs =
      match?({"true\n", 0}, Git.run(b.root, ["config", "--bool", "--get", "commit.gpgsign"]))

    signed = Regex.match?(~r/^gpgsig(-sha256)? /m, Git.ok!(b.root, ["cat-file", "commit", new]))

    if tree != pass.tree or parent != b.start or (signs and not signed) do
      undo!(b, new)

      paths =
        case Snapshot.changed(b.root, pass.tree, tree) do
          [] -> ["the commit itself"]
          changed -> changed
        end

      throw(
        {:failed, b,
         %Error{
           class: "candidate",
           reason: "hook_changed_commit",
           detail:
             "a commit hook changed #{Enum.join(paths, ", ")}; the commit was undone and the changes are left in place",
           exit: 1
         }}
      )
    end

    # The commit is still ours to undo until every postcommit query has completed.
    Bridge.check_cancel()
    Process.delete(:kogen_committing)
    File.rm(Intent.approval_path(b.root, b.slug))
    b = save(b, %{stage: :landed, commit: new})
    sha8 = String.slice(new, 0, 8)
    notes = for f <- review.findings, f["severity"] == "note", do: f
    Run.log(b.run, %{"event" => "outcome", "outcome" => "landed", "commit" => new})
    Run.write(b.run, "result.json", result(b, "landed", %{"commit" => new}))

    Bridge.puts("landed #{b.slug} #{sha8} (Build #{b.run.id})")
    Bridge.puts("  checks: " <> checks_line(pass))

    Bridge.puts(
      "  review: approved" <> if(notes == [], do: "", else: ", #{length(notes)} note(s)")
    )

    for f <- notes, do: Bridge.puts("  note: #{f["path"]}:#{f["line"]}: #{f["message"]}")

    Bridge.puts(
      "  repairs: #{b.repairs} · tokens: #{Usage.total(b.usage)} · time: #{duration(b)}"
    )

    throw({:landed, 0})
  end

  # Moves HEAD back from Kogen's own just-made commit (GIT-6); `details/2` restores the index.
  defp undo!(b, new) do
    Git.ok!(b.root, [
      "update-ref",
      "-m",
      "kogen: undo the unverified commit",
      "HEAD",
      b.start,
      new
    ])
  end

  defp checks_line(pass) do
    a = pass.acceptance
    model = if pass.model == :none, do: "model not applicable", else: "model passed"

    Enum.join(
      ["acceptance #{a.passed}/#{length(a.scenarios)}", model] ++
        Enum.map(pass.checks, &"#{&1.name} passed"),
      ", "
    )
  end

  defp duration(b) do
    s = div(System.monotonic_time(:millisecond) - b.t0, 1000)

    cond do
      s >= 3600 -> "#{div(s, 3600)}h#{pad(rem(div(s, 60), 60))}m#{pad(rem(s, 60))}s"
      s >= 60 -> "#{div(s, 60)}m#{pad(rem(s, 60))}s"
      true -> "#{s}s"
    end
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  # ---- Ends without a commit (GIT-8, CLI-7) ----

  defp stopped(b, %Error{class: "provider", reason: "context_too_long"} = e) do
    model = b.config.models["build"].model

    stopped(b, %Error{
      class: "candidate",
      reason: "context_exhausted",
      detail: "the conversation no longer fits #{model}'s context; edits are left in place",
      lines: e.lines,
      provider_failure: e.provider_failure,
      exit: 1
    })
  end

  defp stopped(b, %Error{} = e) do
    report = b.phase != :startup
    if report, do: Bridge.puts("failed #{b.slug}: #{e.reason} (Build #{b.run.id})")
    Bridge.out(Error.render(e))
    details(b, e.reason, report, e.provider_failure)
    e.exit
  end

  defp interrupted(b, sig) do
    # An interrupt during git commit may still have let the commit land (CLI-7, GIT-6).
    if Process.get(:kogen_committing) do
      head = Git.head(b.root)
      if head != b.start, do: undo!(b, head)
    end

    Bridge.puts("stopped #{b.slug}: interrupted (Build #{b.run.id})")

    Bridge.puts(
      "candidate/interrupted: Build #{b.run.id} stopped by #{sig}; edits are left in place"
    )

    details(b, "interrupted")
    Kogen.Main.signal_exit(sig)
  end

  defp details(b, reason, report \\ true, provider_failure \\ nil) do
    File.cp!(Path.join(b.run.dir, "index-at-start"), b.git_index)
    still = (b.last_pass && b.last_pass.failing) || []

    still =
      if b.last_pass && b.last_pass.moved != [], do: still ++ ["verification"], else: still

    still =
      if b.last_review && b.last_review.verdict != "approve", do: still ++ ["review"], else: still

    edited = Snapshot.changed(b.root, b.start_tree, Snapshot.tree(b.root, b.start, b.excluded))

    if report do
      if still != [], do: Bridge.puts("  still failing: #{Enum.join(still, ", ")}")
      if edited != [], do: Bridge.puts("  edited: #{Enum.join(edited, ", ")}")
      Bridge.puts("  run log: #{b.run.log}")
    end

    outcome = %{"event" => "outcome", "outcome" => reason}

    outcome =
      if provider_failure,
        do: Map.put(outcome, "provider_failure", provider_failure),
        else: outcome

    Run.log(b.run, outcome)

    extra = %{"edited" => edited, "still_failing" => still}
    extra = if b.blocker, do: Map.put(extra, "blocker", b.blocker), else: extra

    extra =
      if provider_failure,
        do: Map.put(extra, "provider_failure", provider_failure),
        else: extra

    Run.write(b.run, "result.json", result(b, reason, extra))
    save(b, b.continuation)
  end

  defp result(b, outcome, extra) do
    Map.merge(
      %{
        "slug" => b.slug,
        "build" => b.run.id,
        "outcome" => outcome,
        "start_head" => b.start,
        "passes" => b.pass,
        "reviews" => b.review,
        "repairs" => b.repairs,
        "usage" => b.usage,
        "model_active_ms" => b.model_active_ms,
        "unknown_requests" => b.unknown_requests,
        "attempt_usage" => b.attempt_usage,
        "resumed_from" => b.parent,
        "root_build" => b.root_run
      },
      extra
    )
  end

  # ---- Requests ----

  @doc false
  def request(b, role_name, role, instructions, input, tools) do
    Bridge.check_cancel()
    t0 = System.monotonic_time(:millisecond)
    Bridge.progress("kogen: #{role_name} request #{role.model}/#{role.effort}")
    Process.put(:kogen_build, %{b | unknown_requests: b.unknown_requests + 1})
    b = save(Process.get(:kogen_build), b.continuation)
    resp = ChatGPT.respond(role, instructions, input, tools)
    wall = System.monotonic_time(:millisecond) - t0

    Process.put(:kogen_build, %{
      b
      | unknown_requests: b.unknown_requests - 1,
        model_active_ms: b.model_active_ms + wall,
        attempt_usage: Usage.add(b.attempt_usage, resp.usage),
        usage: Usage.add(b.usage, resp.usage)
    })

    b = Process.get(:kogen_build)
    save(b, %{stage: :tool, owner: role_name, response: resp.items})
    Bridge.progress("kogen: #{role_name} response #{Usage.line(resp.usage)} wall_ms=#{wall}")

    Run.log(b.run, %{
      "event" => "request",
      "role" => role_name,
      "model" => role.model,
      "effort" => role.effort,
      "usage" => resp.usage,
      "wall_ms" => wall
    })

    resp
  end

  # ---- Prompts (LOOP-2) ----

  defp context(b) do
    model_text =
      case File.read(Path.join(b.root, Intent.model_path(b.slug))) do
        {:ok, t} -> "\n# model.qnt\n\n```quint\n#{t}```\n"
        _ -> ""
      end

    """
    # Intent: #{b.intent.title}

    ```markdown
    #{b.intent.text}```

    # Acceptance feature (#{Intent.feature(b.slug)})

    ```gherkin
    #{File.read!(Path.join(b.root, Intent.feature(b.slug)))}```
    #{model_text}
    # Project instructions (README.md)

    #{Shape.readme(b.root)}

    # Testing rules (docs/testing-rules.md)

    #{Kogen.testing_rules()}

    # Configured commands

    setup: #{inspect(b.config.setup)}
    fix (run once after each of your rounds): #{inspect(b.config.fix)}
    checks: #{Enum.map_join(b.config.checks, "; ", fn {n, r} -> "#{n}: #{r}" end)}
    acceptance: #{b.config.acceptance_run} (runs #{Intent.feature(b.slug)})

    # Protected paths

    These files are the approved acceptance baseline. Approval freezes these bytes; it is not an exception or authorization to change them. write_file refuses them, and if any of them changes the Build stops at once without a commit:
    #{Enum.map_join(b.baseline, "\n", &("- " <> &1))}

    Dependency manifests and lockfiles that are not in this baseline remain editable inputs for approved implementation changes. Their editable portions do not authorize weakening, removing or bypassing a configured check or changing actual verification configuration. Preserve all configured checks, their commands and the behavior they verify. Protection is whole-file: if a combined check-definition manifest is listed above, it cannot be edited for dependencies either.

    # Files

    #{Git.ok!(b.root, ["ls-files", "--cached", "--others", "--exclude-standard"])}
    """
  end

  defp builder_instructions do
    """
    You implement an approved Intent in this Git repository with shell, read_file, write_file, finish and report_blocker. Follow the approved Intent and the project's README and conventions.

    Rules:
    - Start with the relevant implementation and test owners. Batch independent reads, search for specific symbols instead of surveying the whole repository, and implement a small testable increment before expanding inspection. Reuse information already read; do not repeatedly reread unchanged source.
    - Write and update tests as the Intent's `## Tests` section and the testing rules say. Use focused tests or fail-fast runs while debugging. Kogen owns the complete acceptance/project gate at finish; avoid duplicating that whole gate in shell. Preserve failed test exit statuses when printing diagnostic logs.
    - Implement exactly what the Intent asks. No unrequested features, settings, abstractions, fallbacks or defensive branches. When behavior changes, change the existing code path, rewire its callers and delete obsolete code, tests and docs in the same change.
    - Approval freezes the protected baseline (the Intent's files, its Acceptance paths, .kogen/project.yaml and protected check configuration); it is not authorization to change those files. write_file refuses them, and changing them by any other means stops the Build without a commit.
    - Editable dependency manifests and lockfiles may change for an approved feature, but that does not permit weakening, removing or bypassing configured checks or changing actual verification configuration. Preserve every check and its behavior. Protection is whole-file: a protected combined manifest that defines checks has no dependency-only exception.
    - shell runs /bin/sh -c in the repository root with stdin closed, so a command that asks for input fails at once. Commands have no time limit. Run finite tests and browser suites in the foreground until completion, even when they take minutes; do not poll them through repeated sleep/tail/ps calls. Only persistent commands (dev servers, watch modes) run in the background with output to a log file (`cmd > log 2>&1 &`); read their logs and stop them with kill when done.
    - Do not commit, push, stash, reset or switch branches; Kogen commits after verification and review.
    - When the implementation is complete, call finish. Kogen runs the fixers, the acceptance scenarios, the model and every check. Verification failures come back to you; fix them and call finish again. After a green pass an independent reviewer investigates and repairs supported defects, then Kogen verifies any changed contents. Repair ordinary implementation failures and expected missing-feature red. If observed evidence demonstrates that current protected files contradict the approved behavior or contain a fixture defect, use report_blocker with their exact protected paths, a concrete reason and observed command/step/error evidence. Do not change production semantics solely to accommodate a demonstrated bad fixture. A valid report stops as BUILDER-REPORTED build_blocked with candidate/index/approval preserved; it is not independently proven and grants no protected edits, automatic refinement or approval. Plain blocked text does not stop the Build.
    """
  end
end
