defmodule Kogen.WarmCheckTest do
  use ExUnit.Case, async: true

  # Subprocesses run from this checkout, never the shared VM's mutable cwd.
  @project_root Path.expand("../..", __DIR__)
  alias Kogen.Build.VerificationPlan

  test "rehearsal receipts bind to the suite tests the command selects" do
    alias Kogen.Build.RehearsalBinding

    events =
      """
      {"file":"test/kogen/warm_check_test.exs","status":"passed"}
      {"file":"test/kogen/failing_test.exs","status":"passed"}
      {"file":"test/kogen/failing_test.exs","status":"failed"}
      """
      |> RehearsalBinding.statuses_by_file()

    root = @project_root

    assert RehearsalBinding.bound?(
             ~w(mix test --exclude live test/kogen/warm_check_test.exs),
             events,
             root
           )

    # Negative controls: a nonexistent file, a file with no events, a file with
    # a failed test and a command selecting no test file are never bound.
    refute RehearsalBinding.bound?(
             ~w(mix test --exclude live test/kogen/no_such_rehearsal_test.exs),
             Map.put(events, "test/kogen/no_such_rehearsal_test.exs", ["passed"]),
             root
           )

    refute RehearsalBinding.bound?(
             ~w(mix test --exclude live test/kogen/warm_check_test.exs test/kogen/no_such_rehearsal_test.exs),
             events,
             root
           )

    refute RehearsalBinding.bound?(
             ~w(mix test --exclude live test/kogen/lifecycle_test.exs),
             events,
             root
           )

    refute RehearsalBinding.bound?(
             ~w(mix test --exclude live test/kogen/failing_test.exs),
             events,
             root
           )

    refute RehearsalBinding.bound?(~w(mix test --exclude live), events, root)
  end

  test "a silent stage is a stall failure while a slow chatty stage passes" do
    program = ~S'''
    import importlib.util, json, os, sys
    spec = importlib.util.spec_from_file_location("offline", sys.argv[1])
    offline = importlib.util.module_from_spec(spec); spec.loader.exec_module(offline)
    # Output is continuous until a deadline event (no sleeps between lines), so a
    # loaded machine cannot open a silence gap; the run outlasts the limit.
    slow = "end=$(( $(date +%s) + 2 )); while [ $(date +%s) -lt $end ]; do echo tick; done"
    silent = "import time; time.sleep(30)"
    out = {}
    env = dict(os.environ, KOGEN_OFFLINE_STAGE_TIMEOUT="1")
    out["slow"] = offline.run_stage(["/bin/sh", "-c", slow], ".", env)["exit_code"]
    env = dict(os.environ, KOGEN_OFFLINE_STAGE_TIMEOUT="0.5")
    silent_result = offline.run_stage([sys.executable, "-c", silent], ".", env)
    out["silent"] = silent_result["exit_code"]
    out["log"] = silent_result["bounded_log"]
    print(json.dumps(out))
    '''

    {output, 0} =
      System.cmd(
        "python3",
        ["-B", "-c", program, Path.join(@project_root, "scripts/check/offline.py")],
        stderr_to_stdout: true,
        cd: @project_root
      )

    result = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
    # Total elapsed (>=1s) exceeds the 1s limit; only silence is a failure.
    assert result["slow"] == 0
    assert result["silent"] == 124
    assert result["log"] =~ "stage stalled: no output for"
  end

  test "warm Candidate events belong only to the complete test stage" do
    root = Path.expand("../..", __DIR__)

    program = ~S'''
    import importlib.util, json, pathlib, sys
    spec = importlib.util.spec_from_file_location("offline", sys.argv[1])
    offline = importlib.util.module_from_spec(spec); spec.loader.exec_module(offline)
    observed = []
    def capture(command, root, env, timeout):
        observed.append({"command":command, "event_log":env.get("KOGEN_TEST_EVENT_LOG"),
                         "owner_pid":env.get("KOGEN_TEST_EVENT_OWNER_PID"),
                         "timings":env.get("KOGEN_TEST_TIMING_SUMMARY")})
        return 0, "", {"status":"not-required"}
    offline.run_bounded_capture = capture
    env = {"KOGEN_TEST_EVENT_LOG":"candidate.jsonl", "KOGEN_TEST_EVENT_OWNER_PID":"outer",
           "KOGEN_TEST_TIMING_SUMMARY":"candidate-timings.json",
           "KOGEN_OFFLINE_STAGE_TIMEOUT":"1"}
    offline.run_stage(list(offline.TEST_COMPILE_STAGE), pathlib.Path("."), env)
    offline.run_stage(list(offline.STAGES[3]), pathlib.Path("."), env)
    offline.run_stage(["mix", "run", "scripts/check/rehearsals.exs"], pathlib.Path("."), env)
    print(json.dumps(observed))
    '''

    {output, 0} =
      System.cmd("python3", ["-B", "-c", program, Path.join(root, "scripts/check/offline.py")],
        stderr_to_stdout: true,
        cd: @project_root
      )

    observed = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
    assert Enum.map(observed, & &1["event_log"]) == [nil, "candidate.jsonl", nil]
    assert Enum.map(observed, & &1["owner_pid"]) == [nil, "outer", nil]
    assert Enum.map(observed, & &1["timings"]) == [nil, "candidate-timings.json", nil]
  end

  test "a nested Candidate suite that inherits an owner path it does not own never contaminates the candidate log" do
    root = Path.expand("../..", __DIR__)

    directory =
      Path.join(
        System.tmp_dir!(),
        "kogen-warm-nested-owner-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    event_log = Path.join(directory, "candidate.jsonl")

    # Simulates what a fixture Build's nested `mix test` inherits from a real
    # complete check run: the same KOGEN_TEST_EVENT_LOG and a matching
    # KOGEN_TEST_EVENT_OWNER_PATH (test_helper.exs only reassigns ownership
    # when the path changes), but an KOGEN_TEST_EVENT_OWNER_PID that belongs
    # to a different (the real outer) OS process, never this nested one.
    {_output, 0} =
      System.cmd(
        "mix",
        ["test", "--exclude", "live", "test/kogen/claude_code_install_test.exs"],
        cd: root,
        env: [
          {"KOGEN_TEST_EVENT_LOG", event_log},
          {"KOGEN_TEST_EVENT_OWNER_PATH", event_log},
          {"KOGEN_TEST_EVENT_OWNER_PID", "not-this-nested-process"},
          {"KOGEN_TEST_DRY_RUN", nil}
        ],
        stderr_to_stdout: true
      )

    refute File.exists?(event_log),
           "a nested suite wrote to the candidate log it does not own: #{inspect(File.read(event_log))}"
  end

  test "immutable base enumeration uses installed dependencies and compiles its own application" do
    root = Path.expand("../..", __DIR__)

    program = ~S'''
    import importlib.util, json, os, pathlib, shutil, sys, tempfile
    root = pathlib.Path(sys.argv[1])
    spec = importlib.util.spec_from_file_location("offline", root / "scripts/check/offline.py")
    offline = importlib.util.module_from_spec(spec); spec.loader.exec_module(offline)
    capture = offline.run_bounded_capture
    def capture_without_candidate_app(command, cwd, env, timeout):
        assert not (cwd / "_build/lib/kogen").exists(), "Candidate application build was copied"
        return capture(command, cwd, env, timeout)
    offline.run_bounded_capture = capture_without_candidate_app
    with tempfile.TemporaryDirectory(prefix="kogen-base-enumeration-test-") as temporary:
        manifest = offline.make_base_manifest(root, shutil.which("git"),
                                              dict(os.environ), temporary)
        base = pathlib.Path(temporary) / "base"
        print(json.dumps({
            "tests": len(manifest["tests"]),
            "dependency": (base / "_build/lib/yamerl/ebin/yamerl.app").is_file(),
            "base_application": (base / "_build/lib/kogen/ebin/Elixir.Kogen.Build.beam").is_file(),
            "base_source": (base / "lib/kogen/build.ex").is_file()
        }))
    '''

    {output, 0} =
      System.cmd("python3", ["-B", "-c", program, root],
        stderr_to_stdout: true,
        cd: @project_root
      )

    result = output |> String.trim() |> Jason.decode!()
    assert result["tests"] > 0
    assert result["dependency"]
    assert result["base_application"]
    assert result["base_source"]
  end

  test "warm base enumeration trusts only its exported mise config" do
    root = Path.expand("../..", __DIR__)

    program = ~S'''
    import importlib.util, json, os, pathlib, shutil, subprocess, sys, tempfile
    spec = importlib.util.spec_from_file_location("offline", sys.argv[1])
    offline = importlib.util.module_from_spec(spec); spec.loader.exec_module(offline)

    with tempfile.TemporaryDirectory(prefix="kogen-warm-mise-") as temporary:
        base = pathlib.Path(temporary) / "base"
        base.mkdir()
        config = base / "mise.toml"
        shutil.copyfile(sys.argv[2], config)
        original = config.read_bytes()
        env = dict(os.environ, MISE_TRUSTED_CONFIG_PATHS="",
                   KOGEN_TEST_EVENT_OWNER_PID="inherited",
                   KOGEN_TEST_EVENT_OWNER_PATH="inherited",
                   MIX_BUILD_PATH="/candidate/_build",
                   MIX_DEPS_PATH="/candidate/deps",
                   MISE_STATE_DIR=str(pathlib.Path(temporary) / "state"))
        before = subprocess.run(["mise", "which", "python3"], cwd=base, env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        enumeration = offline.base_enumeration_env(env, base, base / "events.jsonl")
        after = subprocess.run(["mise", "which", "python3"], cwd=base, env=enumeration,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        print(json.dumps({"before":before.returncode, "after":after.returncode,
                          "trusted":enumeration["MISE_TRUSTED_CONFIG_PATHS"],
                          "build_path":enumeration["MIX_BUILD_PATH"],
                          "candidate_deps_override":"MIX_DEPS_PATH" in enumeration,
                          "owner_cleared":"KOGEN_TEST_EVENT_OWNER_PID" not in enumeration and "KOGEN_TEST_EVENT_OWNER_PATH" not in enumeration,
                          "config":str(config), "unchanged":config.read_bytes() == original,
                          "python":after.stdout.strip().splitlines()[-1] if after.stdout else ""}))
    '''

    {output, 0} =
      System.cmd(
        "python3",
        [
          "-B",
          "-c",
          program,
          Path.join(root, "scripts/check/offline.py"),
          Path.join(root, "mise.toml")
        ],
        stderr_to_stdout: true,
        cd: @project_root
      )

    result = output |> String.trim() |> Jason.decode!()
    assert result["before"] != 0
    assert result["after"] == 0
    assert result["trusted"] == result["config"]
    assert result["build_path"] == Path.join(Path.dirname(result["config"]), "_build")
    refute result["candidate_deps_override"]
    assert result["owner_cleared"]
    assert result["unchanged"]
    assert File.regular?(result["python"])
  end

  test "immutable base dry run emits identities with its committed helper" do
    root = Path.expand("../..", __DIR__)

    directory =
      Path.join(System.tmp_dir!(), "kogen-warm-base-events-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    event_log = Path.join(directory, "events.jsonl")

    program = """
    Code.require_file("test/support/timing_formatter.ex")
    test = %{module: Kogen.ImmutableBase, name: :"test legacy",
             tags: %{file: Path.expand("test/legacy.exs")}, state: nil}
    Kogen.TimingFormatter.handle_cast(
      {:module_finished, %{tests: [test], parameters: %{n: 1}}}, {[], :unknown})
    """

    {_, 0} =
      System.cmd("mix", ["run", "--no-start", "-e", program],
        cd: root,
        env: [
          {"KOGEN_TEST_EVENT_LOG", event_log},
          {"KOGEN_TEST_DRY_RUN", "1"},
          {"KOGEN_TEST_EVENT_OWNER_PID", nil},
          {"KOGEN_TEST_EVENT_OWNER_PATH", nil}
        ],
        stderr_to_stdout: true
      )

    assert [event] = event_log |> File.stream!() |> Enum.map(&Jason.decode!/1)
    assert event["file"] == "test/legacy.exs"
    assert event["parameters"] == %{"n" => 1}
    assert event["status"] == "enumerated"
  end

  test "base dry run records each parameterized case as a distinct identity" do
    root = Path.expand("../..", __DIR__)

    directory =
      Path.join(System.tmp_dir!(), "kogen-warm-identities-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    event_log = Path.join(directory, "events.jsonl")

    {output, 0} =
      System.cmd(
        "mix",
        ["test", "--dry-run", "test/kogen/approved_mutation_test.exs"],
        cd: root,
        env: [{"KOGEN_TEST_DRY_RUN", "1"}, {"KOGEN_TEST_EVENT_LOG", event_log}],
        stderr_to_stdout: true
      )

    assert output =~ "Tests that would be executed:"

    events = event_log |> File.stream!() |> Enum.map(&Jason.decode!/1)
    assert length(events) == 9

    identities =
      Enum.map(events, fn event ->
        {event["file"], event["module"], event["name"], event["parameters"]}
      end)

    assert length(Enum.uniq(identities)) == 9
    assert Enum.all?(events, &(&1["status"] == "enumerated"))
  end

  test "admission proof accepts a complete control and rejects every missing or altered proof input" do
    root = Path.expand("../..", __DIR__)

    program = ~S'''
    import hashlib, importlib.util, json, pathlib, sys
    spec = importlib.util.spec_from_file_location("offline", sys.argv[1])
    offline = importlib.util.module_from_spec(spec); spec.loader.exec_module(offline)

    base_test = {"file":"test/base.exs", "module":"Elixir.Base", "name":"test stable", "parameters":{}}
    candidate = [dict(base_test, status="passed"),
                 {"file":"test/new.exs", "module":"Elixir.Added", "name":"test added", "parameters":{}, "status":"passed"}]
    candidate += [{"file":"test/generated.exs", "module":"Elixir.Generated", "name":"test case", "parameters":{"n":n}, "status":"passed"} for n in (1, 2)]
    manifest = {"schema_version":1, "base_commit":"base-head", "exclude":["live"],
                "enumeration_command":"mix test --dry-run --exclude live --seed 1",
                "formatter_sha256":"formatter", "tests":[base_test]}
    digest = lambda value: hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    manifest["manifest_sha256"] = digest(manifest)
    rehearsal = {"schema_version":1,
                 "rehearsals":[{"rehearsal_id":"rehearse-x", "duration_ms":0,
                                 "trace_source":"main-test-suite", "observed":["entry.x"],
                                 "required_trace_assertions":["entry.x"]}],
                 "required_rehearsals":["rehearse-x"],
                 "controlled_prepares":[{"target":"prepare-x", "pass_status":0,
                                          "pass_duration_ms":1, "fail_duration_ms":1,
                                          "pass_observed":["prep.x"],
                                          "required_trace_assertions":["prep.x"], "fail_status":1,
                                          "failure_frame":{"class":"environment"}}],
                 "required_prepares":["prepare-x"]}
    codex_pin = offline.managed_runtime_pin("priv/kogen/codex/install.py")
    claude_pin = offline.managed_runtime_pin("priv/kogen/claude_code/install.py")
    runtime = {"status":"passed", "runtimes":{"codex":{"version":codex_pin},
                                              "claude_code":{"version":claude_pin}}}
    valid = lambda m=manifest, c=candidate, r=rehearsal, rt=runtime: offline.validate_admission_proof(m, c, r, rt)
    failures = {
      "valid": valid(),
      "renamed_or_deleted_test": valid(c=candidate[1:]),
      "failed_base_id": valid(c=[dict(candidate[0], status="failed")] + candidate[1:]),
      "failed_new_test": valid(c=candidate[:1] + [dict(candidate[1], status="failed")] + candidate[2:]),
      "empty_candidate_suite": valid(c=[]),
      "missing_runtime_pin": valid(rt=dict(runtime, runtimes={"codex":{"version":"0.156.1"}, "claude_code":{"version":claude_pin}})),
      "missing_rehearsal": valid(r=dict(rehearsal, rehearsals=[])),
      "failed_prepare": valid(r=dict(rehearsal, controlled_prepares=[dict(rehearsal["controlled_prepares"][0], pass_status=1)])),
      "missing_trace": valid(r=dict(rehearsal, rehearsals=[dict(rehearsal["rehearsals"][0], observed=[])])),
      "missing_trace_declaration": valid(r=dict(rehearsal, rehearsals=[dict(rehearsal["rehearsals"][0], required_trace_assertions=[])])),
      "missing_prepare": valid(r=dict(rehearsal, controlled_prepares=[])),
      "missing_timing": valid(r=dict(rehearsal, controlled_prepares=[dict(rehearsal["controlled_prepares"][0], pass_duration_ms=None)])),
      "duplicate_generated_id": valid(c=candidate + [candidate[-1]]),
    }
    failures["inventory_diff"] = offline.test_inventory_diff(manifest, candidate[1:])
    tampered = json.loads(json.dumps(manifest)); tampered["tests"][0]["name"] = "changed"
    failures["tampered_manifest"] = valid(m=tampered)
    precondition = {"file":"test/kogen/build_preconditions_test.exs",
                    "module":"Elixir.Kogen.BuildPreconditionsTest", "name":"test precondition",
                    "parameters":{"case":"missing policy", "operation":"missing_policy",
                                  "template":"/var/folders/x/kogen-precondition-template-10-20"}}
    changed_template = json.loads(json.dumps(precondition))
    changed_template["parameters"]["template"] = "/var/folders/y/kogen-precondition-template-30-40"
    changed_case = json.loads(json.dumps(changed_template))
    changed_case["parameters"]["case"] = "different case"
    unrelated_template = json.loads(json.dumps(changed_template))
    unrelated_template["parameters"]["template"] = "/var/folders/y/unrelated-template-30-40"
    failures["template_identity_matches"] = offline.test_identity(precondition) == offline.test_identity(changed_template)
    failures["template_inventory_diff_is_canonical"] = offline.test_inventory_diff(
      {"tests":[precondition]}, [changed_template]) == {
        "baseline_count":1, "candidate_count":1, "baseline_only":[], "candidate_only":[]}
    failures["changed_case_stays_distinct"] = offline.test_identity(precondition) != offline.test_identity(changed_case)
    failures["unrelated_path_stays_distinct"] = offline.test_identity(precondition) != offline.test_identity(unrelated_template)
    import inspect
    failures["module_functions"] = [name for name in dir(offline) if not name.startswith("_")]
    failures["validator_parameters"] = list(inspect.signature(offline.validate_admission_proof).parameters)
    print(json.dumps(failures, sort_keys=True))
    '''

    {output, 0} =
      System.cmd(
        "python3",
        ["-B", "-c", program, Path.join(root, "scripts/check/offline.py")],
        stderr_to_stdout: true,
        cd: @project_root
      )

    result = output |> String.trim() |> Jason.decode!()
    assert result["valid"] == []
    assert result["renamed_or_deleted_test"] == []

    assert result["inventory_diff"] == %{
             "baseline_count" => 1,
             "candidate_count" => 3,
             "baseline_only" => [
               %{
                 "file" => "test/base.exs",
                 "module" => "Elixir.Base",
                 "name" => "test stable",
                 "parameters" => %{}
               }
             ],
             "candidate_only" => [
               %{
                 "file" => "test/generated.exs",
                 "module" => "Elixir.Generated",
                 "name" => "test case",
                 "parameters" => %{"n" => 1}
               },
               %{
                 "file" => "test/generated.exs",
                 "module" => "Elixir.Generated",
                 "name" => "test case",
                 "parameters" => %{"n" => 2}
               },
               %{
                 "file" => "test/new.exs",
                 "module" => "Elixir.Added",
                 "name" => "test added",
                 "parameters" => %{}
               }
             ]
           }

    refute "validate_warm_proof" in result["module_functions"]

    assert result["validator_parameters"] ==
             ["base_manifest", "candidate_events", "rehearsal_receipt", "runtime_readiness"]

    assert result["template_identity_matches"]
    assert result["template_inventory_diff_is_canonical"]
    assert result["changed_case_stays_distinct"]
    assert result["unrelated_path_stays_distinct"]

    for failure <-
          ~w(failed_base_id failed_new_test empty_candidate_suite missing_runtime_pin missing_rehearsal failed_prepare missing_trace missing_trace_declaration missing_prepare missing_timing tampered_manifest duplicate_generated_id) do
      assert result[failure] != [], "admission proof accepted #{failure}"
    end
  end

  test "one check run carries the admission proof and diagnostic timing in its own receipt without an elapsed-time cutoff" do
    root = Path.expand("../..", __DIR__)

    directory =
      Path.join(System.tmp_dir!(), "kogen-single-gate-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    program = ~S'''
    import hashlib, importlib.util, json, os, pathlib, sys
    spec = importlib.util.spec_from_file_location("offline", sys.argv[1])
    offline = importlib.util.module_from_spec(spec); spec.loader.exec_module(offline)
    directory = pathlib.Path(sys.argv[2]); variant = sys.argv[3]
    base_test = {"file":"test/base.exs", "module":"Elixir.Base", "name":"test stable", "parameters":{}}
    base = {"schema_version":1, "base_commit":"base", "exclude":["live"],
            "formatter_sha256":"formatter", "tests":[base_test]}
    base["manifest_sha256"] = hashlib.sha256(json.dumps(base, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    base["setup_duration_ms"] = 0
    prepare = {"target":"p", "pass_status":0, "pass_duration_ms":1, "fail_status":1,
               "fail_duration_ms":1, "pass_observed":["prepare"],
               "required_trace_assertions":["prepare"], "failure_frame":{"class":"environment"}}
    rehearsal = {"rehearsals":[{"rehearsal_id":"r", "duration_ms":0,
                                  "trace_source":"main-test-suite", "observed":["entry"],
                                  "required_trace_assertions":["entry"]}],
                 "required_rehearsals":["r"], "controlled_prepares":[prepare],
                 "required_prepares":["p"]}
    if variant == "missing-prepare":
        rehearsal["controlled_prepares"] = []
    events = [dict(base_test, status="passed"),
              {"file":"test/new.exs", "module":"Elixir.New", "name":"test added", "parameters":{}, "status":"passed"}]
    if variant == "renamed-or-deleted-test":
        events = events[1:]
    if variant == "empty-test-suite":
        events = []
    offline.receipt_bindings = lambda *args: {}
    offline.verify_managed_runtimes = lambda *args: {"status":"passed", "duration_ms":0, "runtimes":{
        "codex":{"version":offline.managed_runtime_pin("priv/kogen/codex/install.py")},
        "claude_code":{"version":offline.managed_runtime_pin("priv/kogen/claude_code/install.py")}}}
    offline.make_base_manifest = lambda *args: base
    offline.prepare_isolated_beam_cache = lambda *args: {"duration_ms":0, "cache_sha256":"cache",
        "cached_modules":0, "source_fallbacks":0, "command":["prepare-cache"], "bounded_log":""}
    offline.plan_phases = lambda *args: [["complete-suite"]]
    # The fake prepare target `p` generates no fixture; the stage-generated
    # compatibility fixture record is written below unless the variant omits it.
    offline.PREPARE_WITHOUT_FIXTURE = ("p",)
    clock = [0.0]
    runs = []
    def run_ordered(phases, _root, env, stages):
        runs.append(phases)
        if variant == "cold":
            assert "KOGEN_TEST_EVENT_LOG" not in env and "KOGEN_REHEARSAL_RECEIPT" not in env
            clock[0] = 500.0
            return 0
        pathlib.Path(env["KOGEN_TEST_EVENT_LOG"]).write_text("".join(json.dumps(e) + "\n" for e in events))
        pathlib.Path(env["KOGEN_TEST_TIMING_SUMMARY"]).write_text(json.dumps({
            "cases":[{"duration_us":480000000, "module":"Elixir.Slow", "name":"test slow"}],
            "modules":[{"module":"Elixir.Slow", "duration_us":480000000}]}))
        pathlib.Path(env["KOGEN_REHEARSAL_RECEIPT"]).write_text(json.dumps(rehearsal))
        if variant != "missing-fixture-record":
            pathlib.Path(env["KOGEN_FIXTURE_VALIDATION_RECEIPT"]).write_text(json.dumps(
                {"label":"compatibility-fixture", "digest":"a" * 64, "providers_denied":True, "files":3}) + "\n")
        clock[0] = 500.0
        stages.append({"command":["mix", "test"], "status":"passed", "exit_code":0,
                       "duration_ms":500000, "bounded_log":"", "signature":"s",
                       "cleanup":{"status":"not-required"}})
        return 0
    offline.run_ordered = run_ordered
    offline.time.monotonic = lambda: clock[0]
    os.environ.pop("KOGEN_COLD_OFFLINE", None)
    if variant == "cold":
        def unexpected(*args):
            raise AssertionError("cold-offline must not repeat the admission proof")
        os.environ["KOGEN_COLD_OFFLINE"] = "1"
        offline.validate_cold_environment = lambda *args: []
        offline.validate_provider_denial = lambda *args: []
        offline.verify_managed_runtimes = unexpected
        offline.make_base_manifest = unexpected
        offline.prepare_isolated_beam_cache = unexpected
    os.environ["KOGEN_OFFLINE_INVOCATION"] = "single-gate-" + variant
    os.environ["KOGEN_OFFLINE_RECEIPT"] = str(directory / f"{variant}.json")
    sys.argv[:] = ["offline.py"]
    exit_code = offline.main()
    receipt = json.loads((directory / f"{variant}.json").read_text())
    print(json.dumps({"exit_code":exit_code, "runs":len(runs), "receipt":receipt,
                      "files":sorted(path.name for path in directory.iterdir())}))
    '''

    run = fn variant ->
      {output, 0} =
        System.cmd(
          "python3",
          ["-B", "-c", program, Path.join(root, "scripts/check/offline.py"), directory, variant],
          cd: root,
          stderr_to_stdout: true
        )

      output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
    end

    passed = run.("valid")
    receipt = passed["receipt"]
    assert passed["exit_code"] == 0
    assert passed["runs"] == 1
    assert passed["files"] == ["valid.json"]
    assert receipt["status"] == "passed"
    assert receipt["admission_proof"]["status"] == "passed"
    assert receipt["admission_proof"]["failures"] == []
    assert receipt["admission_proof"]["base_manifest"]["base_commit"] == "base"
    assert length(receipt["admission_proof"]["candidate_tests"]) == 2
    assert receipt["admission_proof"]["required_prepares"] == ["p"]
    assert receipt["bindings"]["admission_proof"]["base_manifest_sha256"] != nil
    refute Map.has_key?(receipt["admission_proof"], "max_seconds")
    assert receipt["timing"]["diagnostic_only"]
    assert receipt["timing"]["whole_gate_duration_ms"] == 500_000
    assert receipt["timing"]["conditions"]["cold_offline"] == false
    assert Map.has_key?(receipt["timing"]["conditions"], "warm_cache")
    assert [%{"duration_ms" => 500_000} | _] = receipt["timing"]["bottlenecks"]["stages"]
    assert [%{"module" => "Elixir.Slow"}] = receipt["timing"]["bottlenecks"]["test_cases"]
    refute Enum.any?(receipt["stages"], &(&1["status"] == "failed"))

    cold = run.("cold")
    assert cold["exit_code"] == 0
    assert cold["runs"] == 1
    assert cold["receipt"]["status"] == "passed"
    refute Map.has_key?(cold["receipt"], "admission_proof")
    assert cold["receipt"]["timing"]["conditions"]["cold_offline"]

    assert receipt["bindings"]["admission_proof"]["validated_fixtures"] == 1

    assert [%{"label" => "compatibility-fixture"}] =
             receipt["admission_proof"]["validated_fixtures"]

    refactored = run.("renamed-or-deleted-test")
    assert refactored["exit_code"] == 0
    assert refactored["receipt"]["admission_proof"]["status"] == "passed"

    assert refactored["receipt"]["admission_proof"]["test_inventory_diff"] == %{
             "baseline_count" => 1,
             "candidate_count" => 1,
             "baseline_only" => [
               %{
                 "file" => "test/base.exs",
                 "module" => "Elixir.Base",
                 "name" => "test stable",
                 "parameters" => %{}
               }
             ],
             "candidate_only" => [
               %{
                 "file" => "test/new.exs",
                 "module" => "Elixir.New",
                 "name" => "test added",
                 "parameters" => %{}
               }
             ]
           }

    for variant <- ["missing-prepare", "empty-test-suite", "missing-fixture-record"] do
      failed = run.(variant)
      assert failed["exit_code"] == 1, variant
      assert failed["runs"] == 1, variant
      assert failed["receipt"]["status"] == "failed", variant
      assert failed["receipt"]["admission_proof"]["status"] == "failed", variant
      assert failed["receipt"]["admission_proof"]["failures"] != [], variant

      assert List.last(failed["receipt"]["stages"])["command"] == [
               "admission-proof-validation"
             ]
    end
  end

  test "the single gate validates every generated fixture with providers denied and rejects each missing proof" do
    root = Path.expand("../..", __DIR__)

    program = ~S"""
    import importlib.util, json, pathlib, sys
    spec = importlib.util.spec_from_file_location("offline", sys.argv[1])
    offline = importlib.util.module_from_spec(spec); spec.loader.exec_module(offline)

    record = lambda label: {"label": label, "digest": "b" * 64, "providers_denied": True, "files": 4}
    def receipt(**changes):
        prepares = []
        for target, labels in offline.PREPARE_FIXTURE_LABELS.items():
            prepares.append({"target": target, "fixture_validations": [record(label) for label in labels]})
        for target in offline.PREPARE_WITHOUT_FIXTURE:
            prepares.append({"target": target})
        prepares = changes.get("prepares", prepares)
        return {"controlled_prepares": prepares}
    stage = [record(label) for label in offline.STAGE_FIXTURE_LABELS]
    check = offline.validate_fixture_proof
    out = {"valid": check(receipt(), stage)}

    dropped = receipt()
    dropped["controlled_prepares"][0]["fixture_validations"] = dropped["controlled_prepares"][0]["fixture_validations"][1:]
    out["missing_label"] = check(dropped, stage)
    undigested = receipt()
    undigested["controlled_prepares"][0]["fixture_validations"][0]["digest"] = "short"
    out["bad_digest"] = check(undigested, stage)
    open_access = receipt()
    open_access["controlled_prepares"][0]["fixture_validations"][0]["providers_denied"] = False
    out["providers_open"] = check(open_access, stage)
    out["missing_stage_record"] = check(receipt(), [])
    out["unknown_prepare"] = check(receipt(prepares=[{"target": "live-new-target"}]), stage)

    # Every catalog prepare target is classified, and the stage is one ordered
    # phase of the single gate after the rehearsals, never a second suite.
    import re
    catalog = pathlib.Path("priv/kogen/verification_targets.yaml").read_text()
    prepare_targets = []
    for block in re.split(r"\n  - name: ", catalog)[1:]:
        if "\n    prepare:" in block:
            prepare_targets.append(block.split("\n", 1)[0].strip())
    classified = set(offline.PREPARE_FIXTURE_LABELS) | set(offline.PREPARE_WITHOUT_FIXTURE)
    out["unclassified_prepares"] = sorted(set(prepare_targets) - classified)
    phases = offline.plan_phases(pathlib.Path("."), "guard", None)
    flat = [command for phase in phases for command in phase]
    stage_command = list(offline.FIXTURE_VALIDATION_STAGE)
    out["stage_count"] = flat.count(stage_command)
    out["stage_after_rehearsals"] = flat.index(stage_command) > flat.index(["mix", "run", "scripts/check/rehearsals.exs"])
    out["stage_name"] = offline._stage_name(stage_command)
    out["suites"] = [command for command in flat if command[:2] == ["mix", "test"] and "--exclude" in command].__len__()

    observed = []
    def capture(command, root, env, timeout):
        observed.append({"command": command, "receipt": env.get("KOGEN_FIXTURE_VALIDATION_RECEIPT")})
        return 0, "", {"status": "not-required"}
    offline.run_bounded_capture = capture
    env = {"KOGEN_FIXTURE_VALIDATION_RECEIPT": "fixtures.jsonl", "KOGEN_OFFLINE_STAGE_TIMEOUT": "1"}
    offline.run_stage(list(offline.STAGES[3]), pathlib.Path("."), env)
    offline.run_stage(stage_command, pathlib.Path("."), env)
    out["receipt_env"] = [item["receipt"] for item in observed]
    print(json.dumps(out))
    """

    {output, 0} =
      System.cmd("python3", ["-B", "-c", program, Path.join(root, "scripts/check/offline.py")],
        cd: root,
        stderr_to_stdout: true
      )

    result = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
    assert result["valid"] == []

    for failure <-
          ~w(missing_label bad_digest providers_open missing_stage_record unknown_prepare) do
      assert result[failure] != [], "fixture proof accepted #{failure}"
    end

    assert result["unclassified_prepares"] == []
    assert result["stage_count"] == 1
    assert result["stage_after_rehearsals"]
    assert result["stage_name"] == "fixture-validation"
    # The complete test run plus the load-only compile stage; no second suite.
    assert result["suites"] == 2
    assert result["receipt_env"] == [nil, "fixtures.jsonl"]
  end

  test "the catalog and Makefile select one complete offline check and no timed warm duplicate" do
    root = Path.expand("../..", __DIR__)
    {:ok, catalog} = VerificationPlan.load(root)
    makefile = File.read!(Path.join(root, "Makefile"))

    refute "warm-check" in catalog.ordered_targets
    assert Enum.take(catalog.ordered_targets, 2) == ["check", "cold-offline"]
    refute makefile =~ "warm-check"
    refute makefile =~ "--max-seconds"
    refute makefile =~ "--warm-proof"
    assert length(Regex.scan(~r/scripts\/check\/offline\.py/, makefile)) == 1
    assert catalog.targets["cold-offline"]["cost_class"] == "offline-cold"
    assert catalog.targets["cold-offline"]["dependencies"] == ["check"]
  end
end
