Code.require_file("fake_jev.ex", __DIR__)

defmodule Kogen.ScriptedBuildFixture do
  @moduledoc false

  # A disposable project driven through the real `Kogen.Build.run/1` with a
  # scripted Codex-protocol provider and the offline fake Jev. It is shared by
  # the review packet and superseded-objection controls.
  #
  # Options of `run/2`:
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

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Kogen.FakeJev

  @slug "scripted-build"
  @root Path.expand("../..", __DIR__)
  @selector "test/kogen/scripted_selector_test.exs"

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

    File.write!(Path.join(intent, "intent.yaml"), """
    id: 01960000-0000-7000-8000-0000000c0de2
    slug: #{@slug}
    title: Scripted Build fixture
    may_change_guarded_paths: [dummy.txt, target-evidence.txt, target-evidence-manifest.json]
    """)

    File.write!(Path.join(intent, "scenarios.yaml"), Jason.encode!(scenarios()))
    File.write!(Path.join(intent, "risks.yaml"), Jason.encode!(risks()))

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

    jev_responses =
      case Keyword.get(opts, :jev_results) do
        nil -> nil
        results -> FakeJev.record_responses!(Path.join(runtime, "jev-responses"), results)
      end

    env =
      [
        {"KOGEN_HARNESS", Path.join(dir, "provider.py")},
        {"HANDOFF_NOTES_DIR", notes_dir},
        {"HANDOFF_REVIEWS", Keyword.get(opts, :reviews, "accept")},
        {"HANDOFF_RESPONSE_HELPER", Path.join(@root, "test/support/scenario_response.py")},
        {"HANDOFF_FAIL_FIRST", Enum.join(Keyword.get(opts, :fail_first, []), ",")},
        {"HANDOFF_FAIL_ALL", Enum.join(Keyword.get(opts, :fail_all, []), ",")},
        {"HANDOFF_PACKET_MUTATION", to_string(Keyword.get(opts, :packet_mutation, ""))},
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

    try do
      File.cd!(cwd, fn -> Kogen.Build.run(@slug, nil, dir) end)
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      if previous_raw, do: System.put_env("KOGEN_RAW_LOG_DIR", previous_raw)
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
    outer_resumptions: #{outer_resumptions}
    verification_retries: 2
    """
  end

  # Developer turns apply HANDOFF_EDIT_<call>, see the inactive Stop script
  # answer continue, and end with notes-<call>; a controller verification
  # resume continues the same call; Reviewers keep a copy of the packet their context
  # names and answer HANDOFF_REVIEWS in order through scenario_response.py.
  defp provider do
    ~S'''
    #!/usr/bin/env python3
    import json, os, pathlib, shutil, subprocess, sys
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
    if os.environ.get("KOGEN_ROLE") == "reviewer":
        n = count("reviews")
        (state / f"reviewer-prompt-{n}").write_text(prompt)
        lines = prompt.splitlines()
        context = json.loads(lines[lines.index("KOGEN_TASK_CONTEXT") + 1])
        packet = pathlib.Path(context["review_packet"]["path"])
        shutil.copyfile(packet, state / f"reviewer-packet-{n}.json")
        if os.environ.get("HANDOFF_PACKET_MUTATION") == str(n):
            packet.write_bytes(packet.read_bytes().replace(b'"schema_version":1', b'"schema_version":2'))
        verdicts = os.environ.get("HANDOFF_REVIEWS", "accept").split(",")
        verdict = verdicts[min(n, len(verdicts)) - 1]
        out = args[args.index("--output-last-message") + 1]
        response = subprocess.run([sys.executable, os.environ["HANDOFF_RESPONSE_HELPER"], "reviewer", verdict],
                                  input=prompt, capture_output=True, text=True, check=True).stdout
        pathlib.Path(out).write_text(response)
        print(json.dumps({"type": "thread.started", "thread_id": f"review-{n}"}))
        print(json.dumps({"type": "turn.completed", "thread_id": f"review-{n}"}))
        raise SystemExit(0)
    if "--output-last-message" in args or "--output-schema" in args:
        raise SystemExit("Developer turn carried a handoff output schema")
    marker = candidate_runtime / "fail-check"
    session = "developer-session"
    if prompt.startswith("Controller verification failed after your turn"):
        # The controller resumed this same Developer call after a failed cycle.
        call = int((state / "developer-calls").read_text())
        n = count("verification-resumes")
        (state / f"verification-resume-{n}").write_text(prompt)
        if not listed("HANDOFF_FAIL_ALL", call): marker.unlink(missing_ok=True)
    else:
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
    notes_file = pathlib.Path(os.environ["HANDOFF_NOTES_DIR"]) / f"notes-{call}"
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
end
