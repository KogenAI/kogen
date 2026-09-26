Code.require_file("fake_jev.ex", __DIR__)

defmodule Kogen.GenericProjectFixture do
  @moduledoc false

  # Scenario `generic-project-catalog`: a fixture project that is not Kogen
  # and has none of its checks (no `check`, no `cold-offline`, no
  # offline.py, no rehearsals.exs, no ExUnit, no live Shaping driver). Its
  # catalog has one offline target, `test` (arbitrary rank 5), and one
  # provider-backed target, `e2e` (arbitrary rank 50, depending on `test`),
  # with no `prepare` and no Kogen frames in any output (no
  # `KOGEN_FAILURE_SIGNATURE`, no `KOGEN_TARGET_EVIDENCE_MANIFEST`, no
  # `KOGEN_PREPARE_RESULT`). Both Make recipes are plain shell: they fail a
  # fixed number of times, tracked by a gitignored counter file, so the
  # controller's own resumes (not the Developer's) drive them to pass,
  # exactly like a real project's flaky-then-fixed target would.
  #
  # Driven through the real `Kogen.Build.run/1` with a scripted
  # Codex-protocol provider (modeled on `Kogen.ScriptedBuildFixture`), whose
  # every resumed Developer turn changes the Candidate (a tracked scratch
  # file), so the controller's unchanged-Candidate stop never interferes.

  import ExUnit.Callbacks, only: [on_exit: 1]

  @slug "generic-project"
  @root Path.expand("../..", __DIR__)
  @selector "notes.txt"

  def slug, do: @slug

  def fixture!(opts \\ []) do
    dir =
      Path.join(System.tmp_dir!(), "kogen-generic-project-#{System.unique_integer([:positive])}")

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

    File.write!(Path.join(dir, "Makefile"), makefile(Keyword.get(opts, :test_fails, 2)))
    File.mkdir_p!(Path.join(dir, "priv/kogen"))
    File.write!(Path.join(dir, "priv/kogen/verification_targets.yaml"), catalog())

    File.write!(
      Path.join(dir, ".gitignore"),
      ".kogen/build.lock\n.kogen/runtime/\n.kogen/intents/approved/\n"
    )

    File.mkdir_p!(Path.join(dir, ".kogen"))
    File.write!(Path.join(dir, ".kogen/config.yaml"), config())

    for {path, content} <- [{"dummy.txt", "baseline\n"}, {@selector, "focused selector\n"}] do
      File.mkdir_p!(Path.dirname(Path.join(dir, path)))
      File.write!(Path.join(dir, path), content)
    end

    intent = Path.join(dir, ".kogen/intents/approved/#{@slug}")
    File.mkdir_p!(intent)

    File.write!(Path.join(intent, "intent.yaml"), """
    id: 01960000-0000-7000-8000-0000000c0de3
    slug: #{@slug}
    title: Generic project fixture
    may_change_guarded_paths: [dummy.txt]
    """)

    File.write!(Path.join(intent, "scenarios.yaml"), Jason.encode!(scenarios()))
    File.write!(Path.join(intent, "risks.yaml"), Jason.encode!([]))

    # Build admission copies control deps/ into each Candidate.
    File.mkdir_p!(Path.join(dir, "deps"))

    git!(dir, ["init", "-q", "-b", "main"])
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-q", "-m", "baseline"])
    dir
  end

  def run(dir, opts \\ []) do
    runtime = Path.join(dir, ".kogen/runtime")
    notes_dir = Path.join(runtime, "handoff-notes")
    File.mkdir_p!(notes_dir)

    env =
      [
        {"KOGEN_HARNESS", Path.join(dir, "provider.py")},
        {"HANDOFF_NOTES_DIR", notes_dir},
        {"HANDOFF_REVIEWS", Keyword.get(opts, :reviews, "accept")},
        {"HANDOFF_RESPONSE_HELPER", Path.join(@root, "test/support/scenario_response.py")},
        {"FAKE_JEV_LOG_DIR", Path.join(runtime, "fake-jev")},
        {"FAKE_JEV_ANSWERS", "{}"},
        {"FAKE_SECURITY_ITEM", "present"},
        {"KOGEN_JEV_TRANSPORT", Kogen.FakeJev.transport_path()},
        {"KOGEN_JEV_SECURITY", Kogen.FakeJev.security_path()}
      ]

    previous = Map.new(env, fn {key, _value} -> {key, System.get_env(key)} end)
    previous_raw = System.get_env("KOGEN_RAW_LOG_DIR")
    System.delete_env("KOGEN_RAW_LOG_DIR")
    Enum.each(env, fn {key, value} -> System.put_env(key, value) end)

    try do
      File.cd!(dir, fn -> Kogen.Build.run(@slug, nil, dir) end)
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      if previous_raw, do: System.put_env("KOGEN_RAW_LOG_DIR", previous_raw)
    end
  end

  def record!(dir) do
    [path] = Path.wildcard(Path.join(dir, ".kogen/runtime/scenario-tracking/*/record.json"))
    path |> File.read!() |> Jason.decode!()
  end

  defp catalog do
    """
    targets:
      - name: test
        cost_class: offline
        rank: 5
        dependencies: []
        provider_backed: false
        owner: fixture
      - name: e2e
        cost_class: provider
        rank: 50
        dependencies: [test]
        provider_backed: true
        owner: fixture
        rehearsal:
          id: rehearse-e2e
          command: "true"
          shared_entrypoints: ["e2e.entrypoint"]
          correct_fixture: "e2e-correct"
          wrong_fixture: "e2e-wrong"
          trace_assertions: ["e2e-trace"]
    """
  end

  # Plain shell, no Kogen frames: `test` fails `test_fails` times (counted
  # in a gitignored file, independent of the Developer's own state) then
  # passes; `e2e` fails once then passes.
  defp makefile(test_fails) do
    ".PHONY: test e2e\n" <>
      "test:\n" <>
      "\t@mkdir -p .kogen/runtime; n=$$(cat .kogen/runtime/test-fail-count 2>/dev/null || echo 0); if [ $$n -lt #{test_fails} ]; then echo $$((n+1)) > .kogen/runtime/test-fail-count; echo 'test failed: assertion mismatch at spec/app_spec.rb:12'; exit 1; fi; echo test passed\n" <>
      "e2e:\n" <>
      "\t@mkdir -p .kogen/runtime; n=$$(cat .kogen/runtime/e2e-fail-count 2>/dev/null || echo 0); if [ $$n -lt 1 ]; then echo $$((n+1)) > .kogen/runtime/e2e-fail-count; echo 'e2e failed: browser session timed out'; exit 1; fi; echo e2e passed\n"
  end

  defp config do
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
    outer_resumptions: 3
    verification_retries: 2
    offline_retries: 4
    """
  end

  defp scenarios do
    [
      %{
        "id" => "s-generic",
        "given" => "a non-Kogen fixture project",
        "when" => "Build settles the Developer turn",
        "then" => "both targets eventually pass",
        "wrong_result" => "the controller requires a target named check",
        "verified_by" => ["test", "e2e"],
        "evidence" => "scripted provider",
        "proof" => %{
          "offline" => [@selector],
          "paid_target" => "e2e",
          "paid_reason" =>
            "provider-required: e2e; observation: proves the generic catalog works; offline-limit: none",
          "affected_paths" => ["dummy.txt"]
        }
      }
    ]
  end

  # Every resumed Developer turn changes the Candidate (appends to the
  # tracked `dummy.txt`), so the controller's unchanged-Candidate stop never
  # interferes with the deterministic, counter-driven target failures
  # above. No Kogen frame of any kind is ever printed.
  defp provider do
    ~S'''
    #!/usr/bin/env python3
    import json, os, pathlib, subprocess, sys
    home = os.environ.get("KOGEN_HARNESS_HOME")
    state = pathlib.Path(home) / "fake-state" if home else pathlib.Path(".kogen/runtime")
    state.mkdir(parents=True, exist_ok=True)
    args = sys.argv[1:]; prompt = sys.stdin.read()
    def count(name):
        path = state / name
        value = int(path.read_text()) + 1 if path.exists() else 1
        path.write_text(str(value)); return value
    if os.environ.get("KOGEN_ROLE") == "reviewer":
        n = count("reviews")
        (state / f"reviewer-prompt-{n}").write_text(prompt)
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
    session = "developer-session"
    if prompt.startswith("Controller verification failed after your turn"):
        n = count("verification-resumes")
        (state / f"verification-resume-{n}").write_text(prompt)
        with open("dummy.txt", "a") as f: f.write(f"resume-{n}\n")
    else:
        call = count("developer-calls")
        (state / f"developer-prompt-{call}").write_text(prompt)
    hook = subprocess.run(["sh", ".codex/hooks/check.sh"], input=json.dumps({"session_id": session, "thread_id": session}).encode(),
                          capture_output=True, check=True)
    if json.loads(hook.stdout) != {"continue": True}: raise SystemExit("Stop hook acted without a v1 context")
    print(json.dumps({"type": "thread.started", "thread_id": session}))
    print(json.dumps({"type": "item.completed", "item": {"type": "agent_message", "text": "All scenarios are done; nothing is unfinished."}}))
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
