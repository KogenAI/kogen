Code.require_file("fake_jev.ex", __DIR__)

defmodule Kogen.ScriptedBuildFixture do
  @moduledoc false

  # A disposable project driven through the real `Kogen.Build.run/1` with a
  # scripted Codex-protocol provider and the offline fake Jev. It is shared by
  # the review packet and superseded-objection controls.
  #
  # Options of `run/2`:
  #   * `:slug` - approved intent slug (default `scripted-build`)
  #   * `:notes` - Developer notes per call, in order
  #   * `:reviews` - comma-separated Reviewer verdicts, in order
  #   * `:jev_answers` - one static fake Jev override map for every call
  #   * `:jev_results` - recorded fake Jev transport results, one per call
  #   * `:fail_first` - Developer calls whose first controller verification
  #     cycle fails; the controller's resume of the same session fixes it and
  #     a later cycle passes on the same Candidate
  #   * `:fail_all` - Developer calls whose every controller cycle fails
  #   * `:check_output` - characters the check target prints (a two-byte
  #     UTF-8 character, so tails are cut at a code point boundary)
  #   * `:packet_mutation` - the Review number whose Reviewer edits its packet
  #   * `:edits` - shell commands the Developer runs, by call
  #   * `:freeze_resume_edit` - resume numbers (`n`, the controller's own
  #     count of resumed cycles) whose default Candidate-changing resume
  #     edit is suppressed, to exercise the unchanged-Candidate stop
  #   * `:hang` - Developer invocation labels (for example
  #     `developer-1`) that should leave the fake provider hanging
  #
  # `fixture!/1` option `:late_selector` adds a second scenario, `s-late`,
  # whose declared offline proof selector (`@late_selector`) does not exist
  # at admission, so a Build starts with a missing declared proof selector.

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Kogen.Build.Workspace
  alias Kogen.FakeJev

  @slug "scripted-build"
  @root Path.expand("../..", __DIR__)
  @selector "test/kogen/scripted_selector_test.exs"
  @late_selector "test/kogen/scripted_late_selector_test.exs"

  def late_selector, do: @late_selector

  def slug, do: @slug

  def fixture!(opts \\ []) do
    dir =
      Path.join(System.tmp_dir!(), "kogen-scripted-build-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    for path <- [
          ".codex/hooks/check.sh",
          ".codex/hooks/stop_runner.py",
          ".codex/hooks/environment.py",
          ".codex/hooks/verification_policy.py",
          ".codex/hooks.json",
          "priv/kogen/prompts/execution-policy.md",
          "priv/kogen/prompts/developer.md",
          "priv/kogen/prompts/reviewer.md"
        ] do
      target = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(target))
      File.cp!(Path.join(@root, path), target)
    end

    File.chmod!(Path.join(dir, ".codex/hooks/check.sh"), 0o755)
    File.write!(Path.join(dir, "provider.py"), provider())
    File.chmod!(Path.join(dir, "provider.py"), 0o755)

    File.write!(Path.join(dir, "Makefile"), """
    .PHONY: check

    check:
    \t@python3 -c "import os; n = os.environ.get('KOGEN_CHECK_OUTPUT_CHARS'); print(chr(233) * int(n) if n else 'check')"
    \t@test ! -f .kogen/runtime/fail-check
    #{if Keyword.get(opts, :target_evidence), do: target_evidence_recipe(), else: ""}
    """)

    File.mkdir_p!(Path.join(dir, "priv/kogen"))

    File.write!(Path.join(dir, "priv/kogen/verification_targets.yaml"), """
    targets:
      - name: check
        cost_class: offline-complete
        rank: 0
        dependencies: []
        provider_backed: false
        owner: fixture
    """)

    File.write!(
      Path.join(dir, ".gitignore"),
      ".kogen/build.lock\n.kogen/runtime/\n.kogen/intents/approved/\n"
    )

    File.mkdir_p!(Path.join(dir, ".kogen"))

    File.write!(
      Path.join(dir, ".kogen/config.yaml"),
      config(Keyword.get(opts, :outer_resumptions, 3))
    )

    for {path, content} <- [{"dummy.txt", "baseline\n"}, {@selector, "# focused selector\n"}] do
      File.mkdir_p!(Path.dirname(Path.join(dir, path)))
      File.write!(Path.join(dir, path), content)
    end

    intent = Path.join(dir, ".kogen/intents/approved/#{@slug}")
    File.mkdir_p!(intent)

    scenarios =
      if Keyword.get(opts, :late_selector),
        do: scenarios() ++ [late_scenario()],
        else: scenarios()

    write_intent!(intent, "01960000-0000-7000-8000-0000000c0de2", @slug, scenarios)

    # Build admission copies control deps/ into each Candidate.

    File.mkdir_p!(Path.join(dir, "deps"))

    git!(dir, ["init", "-q", "-b", "main"])
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-q", "-m", "baseline"])
    dir
  end

  @doc """
  Appended to the `check` recipe's shell line when `:target_evidence` is set:
  writes an evidence file and its manifest under the Candidate and prints the
  `KOGEN_TARGET_EVIDENCE_MANIFEST` frame `Kogen.Build.TargetEvidence.capture/4`
  reads.
  """
  def target_evidence_recipe do
    "\t@python3 -c \"import hashlib, json; open('target-evidence.txt','w').write('reviewed behavior\\n'); body = open('target-evidence.txt','rb').read(); digest = hashlib.sha256(body).hexdigest(); manifest = json.dumps({'schema_version': 1, 'required_evidence': [{'path': 'target-evidence.txt', 'sha256': digest}]}); open('target-evidence-manifest.json','w').write(manifest); mdigest = hashlib.sha256(manifest.encode()).hexdigest(); print('KOGEN_TARGET_EVIDENCE_MANIFEST\\t' + json.dumps({'manifest_path': 'target-evidence-manifest.json', 'sha256': mdigest}))\"\n"
  end

  def run(dir, opts \\ []) do
    runtime = Path.join(dir, ".kogen/runtime")
    notes_dir = Path.join(runtime, "handoff-notes")
    File.mkdir_p!(notes_dir)

    opts
    |> Keyword.get(:notes, [])
    |> Enum.with_index(1)
    |> Enum.each(fn {notes, call} ->
      File.write!(Path.join(notes_dir, "notes-#{call}"), notes)
    end)

    # A resumed cycle's own final Developer message (distinct from the
    # notes of the call that started the turn), keyed by the controller's
    # own resume count `n`: this is how a real Build lets a Developer object
    # only after an earlier cycle of the same turn already failed, the only
    # way `Kogen.Build.ReviewPacket.superseded_objection/4` can ever see a
    # failed-then-passed history to supersede.
    opts
    |> Keyword.get(:resume_notes, %{})
    |> Enum.each(fn {n, notes} ->
      File.write!(Path.join(notes_dir, "resume-notes-#{n}"), notes)
    end)

    # `environment-and-provider-classes`: each listed invocation
    # (`developer-<n>` counts every Developer launch or resume, `reviewer-<n>`
    # every Review call) prints `:provider_tail` and exits 1 instead of
    # working, as a provider failure would.
    provider_tail = Path.join(runtime, "provider-tail.txt")
    File.write!(provider_tail, Keyword.get(opts, :provider_tail, ""))

    jev_responses =
      case Keyword.get(opts, :jev_results) do
        nil -> nil
        results -> FakeJev.record_responses!(Path.join(runtime, "jev-responses"), results)
      end

    env =
      [
        {"KOGEN_HARNESS", Path.join(dir, "provider.py")},
        # A fixture Build is a fresh controller process from the point of
        # view of the harness. Tests themselves may run inside a Build and
        # therefore inherit both role variables unless they are explicitly
        # scrubbed here.
        {"KOGEN_ROLE", nil},
        {"KOGEN_HARNESS_HOME", nil},
        {"HANDOFF_NOTES_DIR", notes_dir},
        {"HANDOFF_REVIEWS", Keyword.get(opts, :reviews, "accept")},
        {"HANDOFF_RESPONSE_HELPER", Path.join(@root, "test/support/scenario_response.py")},
        {"HANDOFF_FAIL_FIRST", Enum.join(Keyword.get(opts, :fail_first, []), ",")},
        {"HANDOFF_FAIL_ALL", Enum.join(Keyword.get(opts, :fail_all, []), ",")},
        {"HANDOFF_HANG", Enum.join(Keyword.get(opts, :hang, []), ",")},
        {"HANDOFF_FREEZE_RESUME_EDIT",
         Enum.join(Keyword.get(opts, :freeze_resume_edit, []), ",")},
        {"HANDOFF_PACKET_MUTATION", to_string(Keyword.get(opts, :packet_mutation, ""))},
        {"HANDOFF_PROVIDER_FAIL", Enum.join(Keyword.get(opts, :provider_fail, []), ",")},
        {"HANDOFF_NEW_SESSION_ON_RESUME",
         if(Keyword.get(opts, :new_session_on_resume, false), do: "1", else: nil)},
        {"HANDOFF_NEW_SESSION_ON_RESUME_AFTER",
         Keyword.get(opts, :new_session_on_resume_after) |> to_string()},
        {"HANDOFF_PROVIDER_TAIL", provider_tail},
        {"FAKE_JEV_LOG_DIR", Path.join(runtime, "fake-jev")},
        {"FAKE_JEV_ANSWERS", Jason.encode!(Keyword.get(opts, :jev_answers, %{}))},
        {"FAKE_JEV_RESPONSES", jev_responses},
        {"FAKE_SECURITY_ITEM", "present"},
        {"KOGEN_JEV_TRANSPORT", FakeJev.transport_path()},
        {"KOGEN_JEV_SECURITY", FakeJev.security_path()},
        {"KOGEN_CHECK_OUTPUT_CHARS",
         case Keyword.get(opts, :check_output) do
           nil -> nil
           chars -> Integer.to_string(chars)
         end}
      ] ++
        Enum.map(Keyword.get(opts, :edits, %{}), fn {call, command} ->
          {"HANDOFF_EDIT_#{call}", command}
        end)

    previous = Map.new(env, fn {key, _value} -> {key, System.get_env(key)} end)
    previous_raw = System.get_env("KOGEN_RAW_LOG_DIR")
    System.delete_env("KOGEN_RAW_LOG_DIR")

    Enum.each(env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)

    cwd = Keyword.get(opts, :cwd, dir)

    slug = Keyword.get(opts, :slug, @slug)

    try do
      File.cd!(cwd, fn -> Kogen.Build.run(slug, Keyword.get(opts, :route), dir) end)
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      if previous_raw, do: System.put_env("KOGEN_RAW_LOG_DIR", previous_raw)
    end
  end

  @doc "Adds another approved fixture intent to an existing control checkout."
  def add_intent!(dir, slug, id) do
    intent = Path.join(dir, ".kogen/intents/approved/#{slug}")
    File.mkdir_p!(intent)
    write_intent!(intent, id, slug, scenarios())
    :ok
  end

  @doc "Returns every tracking record, oldest first, with its build id and path."
  def records!(dir) do
    dir
    |> Path.join(".kogen/runtime/scenario-tracking/*/record.json")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      build_id = path |> Path.dirname() |> Path.basename()
      {build_id, path, path |> File.read!() |> Jason.decode!()}
    end)
    |> Enum.sort_by(fn {build_id, _path, record} ->
      {Map.get(record, "created_at", ""), build_id}
    end)
  end

  @doc "Starts the fixture controller stand-in in a separate OS process."
  def start_standin!(dir, opts \\ []) do
    executable = System.find_executable("elixir") || raise "elixir executable was not found"
    script = Path.expand("scripted_controller_standin.exs", __DIR__)
    encoded_opts = opts |> Map.new() |> Jason.encode!()

    args =
      Enum.flat_map(code_paths(), fn path -> ["-pa", path] end) ++
        [script, Path.expand(dir), encoded_opts]

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :hide,
          args: Enum.map(args, &String.to_charlist/1),
          env: [{~c"KOGEN_ROLE", false}, {~c"KOGEN_HARNESS_HOME", false}]
        ]
      )

    {:os_pid, pid} = Port.info(port, :os_pid)
    %{port: port, pid: pid}
  end

  @doc "Waits up to one minute for the fake provider's atomic hang marker."
  def await_hanging!(dir), do: await_hanging!(dir, System.monotonic_time(:millisecond) + 60_000)

  defp await_hanging!(dir, deadline) do
    project = Workspace.project_dir(dir)
    paths = Path.wildcard(Path.join(project, "harness/*/fake-state/developer-hanging"))

    case Enum.find_value(paths, &hanging_pid/1) do
      pid when is_integer(pid) ->
        pid

      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise "timed out waiting for developer-hanging"
        end

        Process.sleep(50)
        await_hanging!(dir, deadline)
    end
  end

  defp hanging_pid(path) do
    with {:ok, contents} <- File.read(path),
         {pid, ""} <- Integer.parse(String.trim(contents)),
         true <- pid > 0 do
      pid
    else
      _ -> nil
    end
  end

  @doc "The fake Jev items asked about for this fixture, plus open finding ids."
  def jev_items(finding_ids \\ []) do
    Enum.map(scenarios(), &%{"kind" => "scenario", "id" => &1["id"]}) ++
      Enum.map(risks(), &%{"kind" => "risk", "id" => &1["id"]}) ++
      Enum.map(finding_ids, &%{"kind" => "finding", "id" => &1})
  end

  def record_path!(dir) do
    [path] = Path.wildcard(Path.join(dir, ".kogen/runtime/scenario-tracking/*/record.json"))
    path
  end

  def record!(dir), do: dir |> record_path!() |> File.read!() |> Jason.decode!()

  def reviewer_prompt!(dir, n),
    do: File.read!(Kogen.CandidateFixture.fake_state(dir, "reviewer-prompt-#{n}"))

  def task_context!(prompt) do
    lines = String.split(prompt, "\n")
    index = Enum.find_index(lines, &(&1 == "KOGEN_TASK_CONTEXT"))
    lines |> Enum.at(index + 1) |> Jason.decode!()
  end

  defp scenarios do
    [scenario("s-change"), scenario("s-preserve")]
  end

  defp scenario(id) do
    %{
      "id" => id,
      "given" => "a fixture Candidate",
      "when" => "Build settles the Developer turn",
      "then" => "the fresh Reviewer receives bounded evidence",
      "wrong_result" => "the Reviewer receives unbounded evidence",
      "verified_by" => ["check"],
      "evidence" => "scripted provider",
      "proof" => %{
        "offline" => [@selector],
        "paid_target" => "none",
        "paid_reason" => "offline-sufficient: scripted provider drives the real Build consumer",
        "affected_paths" => ["dummy.txt"]
      }
    }
  end

  defp late_scenario do
    %{
      "id" => "s-late",
      "given" => "a fixture Candidate",
      "when" => "Build settles the Developer turn",
      "then" => "the declared proof selector exists in the Candidate",
      "wrong_result" => "the declared proof selector is missing",
      "verified_by" => ["check"],
      "evidence" => "scripted provider",
      "proof" => %{
        "offline" => [@late_selector],
        "paid_target" => "none",
        "paid_reason" => "offline-sufficient: scripted provider drives the real Build consumer",
        "affected_paths" => [@late_selector]
      }
    }
  end

  defp risks do
    [%{"id" => "r-shared", "scenario_ids" => ["s-change", "s-preserve"], "description" => "x"}]
  end

  defp config(outer_resumptions) do
    """
    default_route: codex
    routes:
      codex:
        harness: codex
        shaping:   {model: fake, effort: low}
        developer: {model: fake, effort: low}
        reviewer:  {model: fake, effort: low}
        helpers:
          scout:  {model: fake, effort: low}
          worker: {model: fake, effort: medium}
          expert: {model: fake, effort: medium}
      codex-alt:
        harness: codex
        shaping:   {model: fake, effort: low}
        developer: {model: fake, effort: low}
        reviewer:  {model: fake, effort: low}
        helpers:
          scout:  {model: fake, effort: low}
          worker: {model: fake, effort: medium}
          expert:  {model: fake, effort: medium}
    outer_resumptions: #{outer_resumptions}
    verification_retries: 2
    offline_retries: 4
    """
  end

  # Developer turns apply HANDOFF_EDIT_<call>, see the inactive Stop script
  # answer continue, and end with notes-<call>; a controller verification
  # resume continues the same call; Reviewers keep a copy of the packet their context
  # names and answer HANDOFF_REVIEWS in order through scenario_response.py.
  defp provider do
    ~S'''
    #!/usr/bin/env python3
    import json, os, pathlib, shutil, subprocess, sys, time
    # Scratch state a test reads back after the Build lives in the Build's
    # harness home, since publication removes the Candidate (where a plain
    # `.kogen/runtime` relative write would otherwise land); outside a Build
    # it falls back to the cwd's ignored .kogen/runtime. The fail-check
    # marker is Candidate-local on purpose: it is written and read back
    # inside the same running Candidate only.
    home = os.environ.get("KOGEN_HARNESS_HOME")
    state = pathlib.Path(home) / "fake-state" if home else pathlib.Path(".kogen/runtime")
    state.mkdir(parents=True, exist_ok=True)
    candidate_runtime = pathlib.Path(".kogen/runtime"); candidate_runtime.mkdir(parents=True, exist_ok=True)
    args = sys.argv[1:]; prompt = sys.stdin.read()
    def count(name):
        path = state / name
        value = int(path.read_text()) + 1 if path.exists() else 1
        path.write_text(str(value)); return value
    def listed(name, call):
        return str(call) in [item for item in os.environ.get(name, "").split(",") if item]
    def provider_failure(label, sid):
        # A scripted provider failure: the recorded tail, then a nonzero exit.
        if not listed("HANDOFF_PROVIDER_FAIL", label): return
        print(json.dumps({"type": "thread.started", "thread_id": sid}))
        sys.stdout.write(pathlib.Path(os.environ["HANDOFF_PROVIDER_TAIL"]).read_text() + "\n")
        raise SystemExit(1)
    def provider_hang(label):
        # The marker is published by rename only after its complete positive
        # pid has been written. The controller tests synchronize on this
        # marker rather than on stand-in output, which can race the provider
        # launch.
        if not listed("HANDOFF_HANG", label): return
        marker = state / "developer-hanging"
        temporary = state / ("developer-hanging.tmp-" + str(os.getpid()))
        temporary.write_text(str(os.getpid()))
        os.replace(temporary, marker)
        while True: time.sleep(1)
    if os.environ.get("KOGEN_ROLE") == "reviewer":
        n = count("reviews")
        # A `resume` reuses the exact thread id Kogen asked for (the
        # `reviewer-reask-once` scenario: the re-ask must stay in the same
        # session), never a freshly minted one.
        is_resume = "resume" in args
        resume_id = args[args.index("resume") + 1] if is_resume else None
        sid = resume_id or f"review-{n}"
        (state / f"reviewer-prompt-{n}").write_text(prompt)
        # A real Reviewer resume continues the same conversation, so it
        # still has the original task context. This fake harness's re-ask
        # prompt (the schema-error text) carries none, so it reuses the most
        # recent fresh launch's stored prompt (never a resume's own, and
        # never an older attempt's) to rebuild the same packet/candidate
        # context on resume.
        fresh_prompt_path = state / "reviewer-prompt-latest-fresh"
        if not is_resume:
            fresh_prompt_path.write_text(prompt)
        context_prompt = fresh_prompt_path.read_text() if is_resume else prompt
        lines = context_prompt.splitlines()
        context = json.loads(lines[lines.index("KOGEN_TASK_CONTEXT") + 1])
        packet = pathlib.Path(context["review_packet"]["path"])
        shutil.copyfile(packet, state / f"reviewer-packet-{n}.json")
        provider_failure(f"reviewer-{n}", sid)
        if os.environ.get("HANDOFF_PACKET_MUTATION") == str(n):
            packet.write_bytes(packet.read_bytes().replace(b'"schema_version":1', b'"schema_version":2'))
        verdicts = os.environ.get("HANDOFF_REVIEWS", "accept").split(",")
        verdict = verdicts[min(n, len(verdicts)) - 1]
        out = args[args.index("--output-last-message") + 1]
        response = subprocess.run([sys.executable, os.environ["HANDOFF_RESPONSE_HELPER"], "reviewer", verdict],
                                  input=context_prompt, capture_output=True, text=True, check=True).stdout
        # `reviewer-reask-once`: HANDOFF_REASK is a comma list, one entry per
        # Review call (fresh launch, then its one resume), each `valid`,
        # `invalid` (strips the first evidence item's `receipt`, so it fails
        # the per-launch schema) or `changed` (schema-valid, but flips
        # `verdict`, a control for "the repair must keep its verdict value").
        reask_modes = [item for item in os.environ.get("HANDOFF_REASK", "").split(",") if item]
        if len(reask_modes) >= n:
            mode = reask_modes[n - 1]
            value = json.loads(response)
            if mode == "invalid":
                del value["scenarios"][0]["evidence"][0]["receipt"]
            elif mode == "changed":
                value["verdict"] = "rework" if value["verdict"] == "accept" else "accept"
            response = json.dumps(value)
        pathlib.Path(out).write_text(response)
        print(json.dumps({"type": "thread.started", "thread_id": sid}))
        print(json.dumps({"type": "turn.completed", "thread_id": sid}))
        raise SystemExit(0)
    if "--output-last-message" in args or "--output-schema" in args:
        raise SystemExit("Developer turn carried a handoff output schema")
    marker = candidate_runtime / "fail-check"
    invocation = count("developer-invocations")
    after = os.environ.get("HANDOFF_NEW_SESSION_ON_RESUME_AFTER")
    changed_after = after and invocation > int(after)
    changed_now = os.environ.get("HANDOFF_NEW_SESSION_ON_RESUME") == "1" or changed_after
    session = "developer-session-2" if "resume" in args and changed_now else "developer-session"
    (state / f"developer-invocation-{invocation}").write_text(" ".join(args))
    (state / f"developer-invocation-{invocation}-prompt").write_text(prompt)
    provider_hang(f"developer-{invocation}")
    provider_failure(f"developer-{invocation}", session)
    if prompt.startswith("Controller verification failed after your turn"):
        # The controller resumed this same Developer call after a failed cycle.
        call = int((state / "developer-calls").read_text())
        n = count("verification-resumes")
        resume_n = n
        (state / f"verification-resume-{n}").write_text(prompt)
        if not listed("HANDOFF_FAIL_ALL", call): marker.unlink(missing_ok=True)
        # A real Developer fixing (or still failing to fix) a failure changes
        # the Candidate; this fake one does too on every resume (unless a
        # test freezes this resume number to exercise the controller's
        # unchanged-Candidate stop on purpose), so that stop is never hit by
        # accident.
        if not listed("HANDOFF_FREEZE_RESUME_EDIT", n):
            with open("dummy.txt", "a") as f: f.write(f"resume-{n}\n")
    else:
        resume_n = None
        call = count("developer-calls")
        (state / f"developer-prompt-{call}").write_text(prompt)
        edit = os.environ.get(f"HANDOFF_EDIT_{call}")
        if edit: subprocess.run(["sh", "-c", edit], check=True)
        if listed("HANDOFF_FAIL_FIRST", call) or listed("HANDOFF_FAIL_ALL", call): marker.touch()
        else: marker.unlink(missing_ok=True)
    # The registered Stop script is a bootstrap remnant: with no v1 context it
    # answers continue without running or recording anything.
    hook = subprocess.run(["sh", ".codex/hooks/check.sh"], input=json.dumps({"session_id": session, "thread_id": session}).encode(),
                          capture_output=True, check=True)
    if json.loads(hook.stdout) != {"continue": True}: raise SystemExit("Stop hook acted without a v1 context")
    # A resumed cycle prefers its own resume-specific notes (a distinct
    # final Developer message for that resumed turn) over the call's
    # original notes.
    resume_notes_file = pathlib.Path(os.environ["HANDOFF_NOTES_DIR"]) / f"resume-notes-{resume_n}" if resume_n else None
    notes_file = resume_notes_file if resume_notes_file and resume_notes_file.exists() else pathlib.Path(os.environ["HANDOFF_NOTES_DIR"]) / f"notes-{call}"
    notes = notes_file.read_text() if notes_file.exists() else "All scenarios are done; nothing is unfinished."
    print(json.dumps({"type": "thread.started", "thread_id": session}))
    print(json.dumps({"type": "item.completed", "item": {"type": "agent_message", "text": notes}}))
    print(json.dumps({"type": "turn.completed", "thread_id": session}))
    '''
  end

  defp git!(dir, args) do
    {_output, 0} =
      System.cmd("git", args,
        cd: dir,
        env: [
          {"GIT_AUTHOR_NAME", "Fixture"},
          {"GIT_AUTHOR_EMAIL", "fixture@example.invalid"},
          {"GIT_COMMITTER_NAME", "Fixture"},
          {"GIT_COMMITTER_EMAIL", "fixture@example.invalid"}
        ]
      )
  end

  defp write_intent!(intent, id, slug, scenarios) do
    File.write!(Path.join(intent, "intent.yaml"), """
    id: #{id}
    slug: #{slug}
    title: Scripted Build fixture
    may_change_guarded_paths: [dummy.txt, target-evidence.txt, target-evidence-manifest.json, #{@late_selector}]
    """)

    File.write!(Path.join(intent, "scenarios.yaml"), Jason.encode!(scenarios))
    File.write!(Path.join(intent, "risks.yaml"), Jason.encode!(risks()))
  end

  defp code_paths do
    :code.get_path()
    |> Enum.map(&List.to_string/1)
    |> Enum.filter(&(Path.type(&1) == :absolute))
    |> Enum.uniq()
  end
end
