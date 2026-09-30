defmodule Kogen.OfflineStageResultsTest do
  use ExUnit.Case, async: true

  # Subprocesses run from this checkout, never the shared VM's mutable cwd.
  @project_root Path.expand("../..", __DIR__)
  @moduletag timeout: 120_000

  test "each stage settles one bounded attributable result and receipt keeps the initiating failure" do
    root = Path.expand("../..", __DIR__)

    receipt =
      Path.join(System.tmp_dir!(), "offline-stage-#{System.unique_integer([:positive])}.json")

    on_exit(fn -> File.rm(receipt) end)

    program = ~S'''
    import importlib.util, json, os, pathlib, sys
    spec = importlib.util.spec_from_file_location("offline", sys.argv[1])
    offline = importlib.util.module_from_spec(spec); spec.loader.exec_module(offline)
    root = pathlib.Path(sys.argv[2]); receipt = pathlib.Path(sys.argv[3])
    ok = offline.run_stage([sys.executable, "-c", "print('positive-stage')"], root, os.environ.copy())
    bad = offline.run_stage([sys.executable, "-c", "print('distinct-stage-failure'); raise SystemExit(17)"], root, os.environ.copy())
    missing = offline.run_stage(["definitely-not-a-kogen-command"], root, os.environ.copy())
    offline.settle_receipt(receipt, "test-invocation", [ok, bad, missing], {"status":"passed","owner":"test"})
    print(json.dumps({"ok": ok, "bad": bad, "missing": missing}))
    '''

    {output, 0} =
      System.cmd(
        "python3",
        ["-c", program, Path.join(root, "scripts/check/offline.py"), root, receipt],
        stderr_to_stdout: true,
        cd: @project_root
      )

    result = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
    settled = receipt |> File.read!() |> Jason.decode!()

    assert result["ok"]["status"] == "passed"
    assert result["bad"]["exit_code"] == 17
    assert result["bad"]["signature"]["error_head"] =~ "distinct-stage-failure"
    assert result["missing"]["exit_code"] == 127
    assert result["missing"]["bounded_log"] =~ "could not launch"
    assert byte_size(result["bad"]["bounded_log"]) <= 16_384
    assert settled["primary_failure"] == result["bad"]["signature"]
    assert settled["cleanup"] == %{"status" => "passed", "owner" => "test"}
  end

  test "atomic settlement replaces a prior receipt instead of appending a partial frame" do
    root = Path.expand("../..", __DIR__)

    receipt =
      Path.join(System.tmp_dir!(), "offline-atomic-#{System.unique_integer([:positive])}.json")

    File.write!(receipt, "stale-partial")
    on_exit(fn -> File.rm(receipt) end)

    program = ~S'''
    import importlib.util, pathlib, sys
    spec = importlib.util.spec_from_file_location("offline", sys.argv[1])
    offline = importlib.util.module_from_spec(spec); spec.loader.exec_module(offline)
    offline.settle_receipt(pathlib.Path(sys.argv[2]), "fresh", [], {"status":"passed"})
    '''

    {_output, 0} =
      System.cmd("python3", ["-c", program, Path.join(root, "scripts/check/offline.py"), receipt],
        stderr_to_stdout: true,
        cd: @project_root
      )

    assert %{"invocation" => "fresh", "schema_version" => 1, "stages" => []} =
             receipt |> File.read!() |> Jason.decode!()
  end

  test "a reaped or misgrouped stage leader cannot signal another process group" do
    root = Path.expand("../..", __DIR__)

    program = ~S'''
    import importlib.util, json, signal, sys
    spec = importlib.util.spec_from_file_location("offline", sys.argv[1])
    offline = importlib.util.module_from_spec(spec); spec.loader.exec_module(offline)
    signals = []
    offline.os.killpg = lambda pid, sig: signals.append([pid, sig])
    class Child:
        pid = 123456789
        def __init__(self, status): self.status = status
        def poll(self): return self.status
    reaped = offline._signal_group(Child(0), signal.SIGTERM)
    offline.os.getpgid = lambda pid: pid + 1
    misgrouped = offline._signal_group(Child(None), signal.SIGKILL)
    print(json.dumps({"reaped": reaped, "misgrouped": misgrouped, "signals": signals}))
    '''

    {output, 0} =
      System.cmd("python3", ["-B", "-c", program, Path.join(root, "scripts/check/offline.py")],
        cd: @project_root
      )

    result = Jason.decode!(String.trim(output))
    assert result["signals"] == []
    assert result["reaped"]["status"] == "failed"
    assert result["misgrouped"]["status"] == "failed"
  end

  test "cleanup failure prevents success and reusable bindings cover every invalidation input" do
    root = Path.expand("../..", __DIR__)

    receipt =
      Path.join(System.tmp_dir!(), "offline-binding-#{System.unique_integer([:positive])}.json")

    on_exit(fn -> File.rm(receipt) end)

    program = ~S'''
    import importlib.util, json, os, pathlib, sys
    spec = importlib.util.spec_from_file_location("offline", sys.argv[1])
    offline = importlib.util.module_from_spec(spec); spec.loader.exec_module(offline)
    root = pathlib.Path(sys.argv[2]); receipt = pathlib.Path(sys.argv[3])
    bindings = {
      "verification_attempt":"bound-attempt", "candidate_sha256":"candidate",
      "source_revision":"revision", "dependency_sha256":"dependencies",
      "toolchain":"toolchain", "catalog_sha256":"catalog",
      "target_plan_sha256":"plan", "provider_denied":True
    }
    offline.settle_receipt(receipt, "bound-attempt", [], {"status":"failed","reason":"owned cleanup"}, bindings)
    print(json.dumps(bindings))
    '''

    {output, 0} =
      System.cmd(
        "python3",
        ["-c", program, Path.join(root, "scripts/check/offline.py"), root, receipt],
        stderr_to_stdout: true,
        cd: @project_root
      )

    bindings = output |> String.trim() |> Jason.decode!()
    settled = receipt |> File.read!() |> Jason.decode!()
    assert settled["status"] == "failed"
    assert settled["primary_failure"] == nil
    assert settled["bindings"] == bindings

    for key <-
          ~w(verification_attempt candidate_sha256 source_revision dependency_sha256 toolchain catalog_sha256 target_plan_sha256 provider_denied) do
      assert Map.has_key?(bindings, key)
    end
  end

  test "the check test stage fails on warnings from excluded live owners" do
    root = Path.expand("../..", __DIR__)

    program = ~S'''
    import importlib.util, json, sys
    spec = importlib.util.spec_from_file_location("offline", sys.argv[1])
    offline = importlib.util.module_from_spec(spec); spec.loader.exec_module(offline)
    print(json.dumps([list(stage) for stage in offline.STAGES]))
    '''

    {output, 0} =
      System.cmd("python3", ["-B", "-c", program, Path.join(root, "scripts/check/offline.py")],
        stderr_to_stdout: true,
        cd: @project_root
      )

    stages = output |> String.trim() |> Jason.decode!()
    test_stage = Enum.find(stages, &match?(["mix", "test" | _], &1))

    assert test_stage == ["mix", "test", "--exclude", "live", "--warnings-as-errors"]
    assert Enum.join(test_stage, " ") =~ "mix test --exclude live"

    # Negative control: an excluded live owner calling a removed Kogen.Harness
    # arity compiles with only a warning, which the stage above makes fatal.
    probe = """
    defmodule Kogen.OfflineStageResultsTest.StaleLiveOwner#{System.unique_integer([:positive])} do
      #{"@module" <> "tag :live"}
      def probe, do: Kogen.Harness.launch_reviewer("p", "m", "e", nil, :removed_extra_arg)
    end
    """

    {_modules, diagnostics} = Code.with_diagnostics(fn -> Code.compile_string(probe) end)

    assert Enum.any?(
             diagnostics,
             &(&1.severity == :warning and
                 &1.message =~ "Kogen.Harness.launch_reviewer/5 is undefined or private")
           )
  end

  test "TEST_COMPILE_STAGE is the probed compile-only command and --only is not used" do
    root = Path.expand("../..", __DIR__)

    program = ~S'''
    import importlib.util, json, sys
    spec = importlib.util.spec_from_file_location("offline", sys.argv[1])
    offline = importlib.util.module_from_spec(spec); spec.loader.exec_module(offline)
    print(json.dumps(list(offline.TEST_COMPILE_STAGE)))
    '''

    {output, 0} =
      System.cmd("python3", ["-B", "-c", program, Path.join(root, "scripts/check/offline.py")],
        stderr_to_stdout: true,
        cd: @project_root
      )

    stage = output |> String.trim() |> Jason.decode!()

    assert stage == [
             "mix",
             "test",
             "--exclude",
             "live",
             "--warnings-as-errors",
             "--exclude",
             "test"
           ]

    refute Enum.any?(stage, &(&1 == "--only"))
  end

  test "the stage plan runs the new compile stage before credo, the full test run and rehearsals, and a failure there stops every later phase (stage-start markers)" do
    root = Path.expand("../..", __DIR__)

    # A fixture stage plan standing in for offline.py's real one: prep
    # (passes), the new compile-only stage (fails, standing in for a planted
    # test-file warning), then credo, the full test run and rehearsals
    # (which must never start). Each fake command touches a Candidate-local
    # marker file the moment it starts, before offline.py's own `run_stage`
    # prints its own start line, so a marker's absence proves the stage
    # never ran.
    program = ~S'''
    import importlib.util, json, os, pathlib, sys
    spec = importlib.util.spec_from_file_location("offline", sys.argv[1])
    offline = importlib.util.module_from_spec(spec); spec.loader.exec_module(offline)
    root = pathlib.Path(sys.argv[2])
    marker = lambda name: root / f"marker-{name}"
    def cmd(name, exit_code=0):
        return [sys.executable, "-c",
                f"import pathlib; pathlib.Path({str(marker(name))!r}).touch(); raise SystemExit({exit_code})"]
    phases = [
        [cmd("prep")],
        [cmd("test-compile", 1)],
        [cmd("credo")],
        [cmd("test")],
        [cmd("rehearsals")],
    ]
    stage_results = []
    exit_code = offline.run_ordered(phases, root, os.environ.copy(), stage_results)
    print(json.dumps({
        "exit_code": exit_code,
        "failing_command": stage_results[-1]["command"],
        "markers": sorted(p.name for p in root.glob("marker-*")),
    }))
    '''

    workdir =
      Path.join(System.tmp_dir!(), "offline-stage-plan-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workdir)
    on_exit(fn -> File.rm_rf(workdir) end)

    {output, 0} =
      System.cmd(
        "python3",
        ["-B", "-c", program, Path.join(root, "scripts/check/offline.py"), workdir],
        stderr_to_stdout: true,
        cd: @project_root
      )

    result = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()

    assert result["exit_code"] == 1
    assert result["markers"] == ["marker-prep", "marker-test-compile"]
    refute "marker-credo" in result["markers"]
    refute "marker-test" in result["markers"]
    refute "marker-rehearsals" in result["markers"]
  end

  test "failure_signature_frame finds the first failing ExUnit test id and assertion, past an isolated-case wrapper banner" do
    root = Path.expand("../..", __DIR__)

    log = """
    Running ExUnit with seed: 909090, max_cases: 12
    Excluding tags: [:live]

    isolated test failed ({:exit_status, 1})

      1) test something isolated fails (Kogen.WrapperTest)
         test/kogen/wrapper_test.exs:9

      1) test something isolated fails (Kogen.WrapperTest)
         test/kogen/wrapper_test.exs:9
         pty success: terminal probe failed: [Errno 9] Bad file descriptor
         code: ...

    Finished in 0.4 seconds
    """

    program = ~S'''
    import importlib.util, sys
    spec = importlib.util.spec_from_file_location("offline", sys.argv[1])
    offline = importlib.util.module_from_spec(spec); spec.loader.exec_module(offline)
    log = open(sys.argv[2]).read()
    print(offline.failure_signature_frame("test", log))
    '''

    log_path =
      Path.join(System.tmp_dir!(), "offline-frame-log-#{System.unique_integer([:positive])}")

    File.write!(log_path, log)
    on_exit(fn -> File.rm(log_path) end)

    {output, 0} =
      System.cmd(
        "python3",
        ["-B", "-c", program, Path.join(root, "scripts/check/offline.py"), log_path],
        stderr_to_stdout: true,
        cd: @project_root
      )

    frame = output |> String.trim() |> Jason.decode!()
    assert frame["stage"] == "test"
    assert frame["test_id"] == "test/kogen/wrapper_test.exs:9"

    assert frame["assertion"] ==
             "pty success: terminal probe failed: [Errno 9] Bad file descriptor"

    refute Map.has_key?(frame, "reproduce")
  end

  # Build jhzmOMHW cycle 1: the full test run was named `test-compile` (every
  # `mix test` argv contains "test") and the reason was unittest's `E..`
  # progress line, so the frame hid which stage and why.
  test "the full test run is stage `test` and a nested unittest failure's reason skips progress and rule lines" do
    root = Path.expand("../..", __DIR__)

    log = """
      1) test offline smoke rehearsal dispatches once (Kogen.ShapingSmokeRehearsalTest)
         test/kogen/shaping_smoke_rehearsal_test.exs:12
         isolated test failed ({:exit_status, 1})

           1) test offline smoke rehearsal dispatches once (Kogen.ShapingSmokeRehearsalTest)
              test/kogen/shaping_smoke_rehearsal_test.exs:12
              E..
              ======================================================================
              ERROR: test_smoke (__main__.DriverSmokeRehearsalTest.test_smoke)
              ----------------------------------------------------------------------
    """

    program = ~S'''
    import importlib.util, json, sys
    spec = importlib.util.spec_from_file_location("offline", sys.argv[1])
    offline = importlib.util.module_from_spec(spec); spec.loader.exec_module(offline)
    print(json.dumps({
        "full": offline._stage_name(["mix", "test", "--exclude", "live", "--warnings-as-errors"]),
        "compile": offline._stage_name(list(offline.TEST_COMPILE_STAGE)),
        "frame": json.loads(offline.failure_signature_frame("test", open(sys.argv[2]).read())),
    }))
    '''

    log_path =
      Path.join(System.tmp_dir!(), "offline-nested-log-#{System.unique_integer([:positive])}")

    File.write!(log_path, log)
    on_exit(fn -> File.rm(log_path) end)

    {output, 0} =
      System.cmd(
        "python3",
        ["-B", "-c", program, Path.join(root, "scripts/check/offline.py"), log_path],
        stderr_to_stdout: true,
        cd: @project_root
      )

    result = output |> String.trim() |> Jason.decode!()
    assert result["full"] == "test"
    assert result["compile"] == "test-compile"
    assert result["frame"]["test_id"] == "test/kogen/shaping_smoke_rehearsal_test.exs:12"

    assert result["frame"]["assertion"] ==
             "ERROR: test_smoke (__main__.DriverSmokeRehearsalTest.test_smoke)"
  end

  test "the --signature-frame CLI prints KOGEN_FAILURE_SIGNATURE with a TAB before the JSON, replaying a captured log" do
    root = Path.expand("../..", __DIR__)

    log = """
    Running ExUnit with seed: 1
    Excluding tags: [:live]

      1) test something fails (Kogen.SomeTest)
         test/kogen/some_test.exs:42
         Assertion with == failed
         code: assert 1 == 2
    """

    log_path =
      Path.join(
        System.tmp_dir!(),
        "offline-signature-cli-log-#{System.unique_integer([:positive])}"
      )

    File.write!(log_path, log)
    on_exit(fn -> File.rm(log_path) end)

    {output, 0} =
      System.cmd(
        "sh",
        [
          "-c",
          "python3 -B #{shell_quote(Path.join(root, "scripts/check/offline.py"))} --signature-frame check < #{shell_quote(log_path)}"
        ],
        stderr_to_stdout: true,
        cd: @project_root
      )

    assert [tag, json] = String.split(String.trim(output), "\t", parts: 2)
    assert tag == "KOGEN_FAILURE_SIGNATURE"
    frame = Jason.decode!(json)
    assert frame["stage"] == "check"
    assert frame["test_id"] == "test/kogen/some_test.exs:42"
    assert frame["assertion"] == "Assertion with == failed"
    refute Map.has_key?(frame, "reproduce")
  end

  test "run_stage attaches a failure_frame only when the stage fails" do
    root = Path.expand("../..", __DIR__)

    program = ~S'''
    import importlib.util, json, os, sys
    spec = importlib.util.spec_from_file_location("offline", sys.argv[1])
    offline = importlib.util.module_from_spec(spec); spec.loader.exec_module(offline)
    root = sys.argv[2]
    ok = offline.run_stage([sys.executable, "-c", "print('fine')"], root, os.environ.copy())
    bad = offline.run_stage(
        [sys.executable, "-c",
         "print('  1) test x fails (M)\\n     f.exs:1\\n     boom'); raise SystemExit(1)"],
        root, os.environ.copy())
    print(json.dumps({"ok": ok["failure_frame"], "bad": bad["failure_frame"]}))
    '''

    {output, 0} =
      System.cmd(
        "python3",
        ["-B", "-c", program, Path.join(root, "scripts/check/offline.py"), root],
        stderr_to_stdout: true,
        cd: @project_root
      )

    result = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
    assert result["ok"] == nil
    frame = Jason.decode!(result["bad"])
    assert frame["test_id"] == "f.exs:1"
    assert frame["assertion"] == "boom"
    assert frame["reproduce"] =~ "MIX_ENV=dev"
  end

  test "run_stage records the final formatter block as structured case timings" do
    root = Path.expand("../..", __DIR__)

    program = ~S'''
    import importlib.util, json, os, sys
    spec = importlib.util.spec_from_file_location("offline", sys.argv[1])
    offline = importlib.util.module_from_spec(spec); spec.loader.exec_module(offline)
    child = """
    print("Slowest individual cases (includes isolated process startup):")
    print("  99.000s Kogen.Nested test stale timing")
    print("Slowest individual cases (includes isolated process startup):")
    print("  1.250s Kogen.SampleTest test slow case")
    print("  0.006s Kogen.SampleTest test fast case")
    """
    stage = offline.run_stage([sys.executable, "-c", child], sys.argv[2], os.environ.copy())
    print(json.dumps(stage))
    '''

    {output, 0} =
      System.cmd(
        "python3",
        ["-B", "-c", program, Path.join(root, "scripts/check/offline.py"), root],
        stderr_to_stdout: true,
        cd: @project_root
      )

    stage = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
    assert stage["status"] == "passed"

    assert stage["case_timings"] == [
             %{
               "duration_ms" => 1_250,
               "module" => "Kogen.SampleTest",
               "name" => "test slow case"
             },
             %{"duration_ms" => 6, "module" => "Kogen.SampleTest", "name" => "test fast case"}
           ]
  end

  # Keep the admission-base test identity while asserting the stronger
  # ownership rule for a leader that exited before its descendant closed stdout.
  test "run_stage bounds concurrent timeouts when descendants hold stdout and group signalling is denied" do
    root = Path.expand("../..", __DIR__)

    workdir =
      Path.join(System.tmp_dir!(), "offline-held-pipe-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workdir)
    on_exit(fn -> File.rm_rf(workdir) end)

    program = ~S'''
    import concurrent.futures, importlib.util, json, os, pathlib, signal, sys, time
    spec = importlib.util.spec_from_file_location("offline", sys.argv[1])
    offline = importlib.util.module_from_spec(spec); spec.loader.exec_module(offline)
    root = pathlib.Path(sys.argv[2]); workdir = pathlib.Path(sys.argv[3])
    real_killpg = os.killpg
    denied = []
    def deny_killpg(pgid, sig):
        denied.append(signal.Signals(sig).name)
        raise PermissionError(1, "Operation not permitted")
    offline.os.killpg = deny_killpg

    def run(slot):
        group_path = workdir / f"group-{slot}"
        child_path = workdir / f"child-{slot}"
        stage = """
    import os, pathlib, subprocess, sys
    child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
    pathlib.Path(sys.argv[1]).write_text(str(os.getpgrp()))
    pathlib.Path(sys.argv[2]).write_text(str(child.pid))
    print("descendant-holds-output", flush=True)
    """
        env = dict(os.environ, KOGEN_OFFLINE_STAGE_TIMEOUT="0.5")
        started = time.monotonic()
        result = offline.run_stage([sys.executable, "-c", stage, str(group_path), str(child_path)], root, env)
        result["wall_seconds"] = time.monotonic() - started
        return result

    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
            results = list(executor.map(run, range(2)))
    finally:
        offline.os.killpg = real_killpg
        for group_path in workdir.glob("group-*"):
            try:
                real_killpg(int(group_path.read_text()), signal.SIGKILL)
            except ProcessLookupError:
                pass
    print(json.dumps({"results": results, "denied": denied}))
    '''

    {output, 0} =
      System.cmd(
        "python3",
        ["-B", "-c", program, Path.join(root, "scripts/check/offline.py"), root, workdir],
        stderr_to_stdout: true,
        cd: @project_root
      )

    result = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
    assert length(result["results"]) == 2
    assert result["denied"] == []

    for stage <- result["results"] do
      assert stage["exit_code"] == 124
      # Termination is proven by the exit code and cleanup record; wall-clock
      # duration is diagnostic only and never a gate under a loaded suite.
      assert is_integer(stage["duration_ms"])
      assert stage["bounded_log"] =~ "descendant-holds-output"
      refute stage["bounded_log"] =~ "process group reaped"
      assert stage["cleanup"]["status"] == "failed"
      assert stage["cleanup"]["leader_reaped"] == true
      assert stage["cleanup"]["output_pipe"] == "closed-by-supervisor"
      assert stage["cleanup"]["descendants"] == "not-independently-verified"
      assert stage["cleanup"]["reason"] =~ "stage leader exited before group ownership"
      refute Map.has_key?(stage["cleanup"], "process_group_reaped")
    end
  end

  test "run_stage falls back to bounded direct-child termination when killpg is denied" do
    root = Path.expand("../..", __DIR__)

    program = ~S'''
    import importlib.util, json, os, signal, sys
    spec = importlib.util.spec_from_file_location("offline", sys.argv[1])
    offline = importlib.util.module_from_spec(spec); spec.loader.exec_module(offline)
    calls = []
    real_killpg = os.killpg
    def deny_killpg(pgid, sig):
        calls.append(signal.Signals(sig).name)
        raise PermissionError(1, "Operation not permitted")
    offline.os.killpg = deny_killpg
    try:
        stage = "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)"
        env = dict(os.environ, KOGEN_OFFLINE_STAGE_TIMEOUT="0.5")
        result = offline.run_stage([sys.executable, "-c", stage], sys.argv[2], env)
    finally:
        offline.os.killpg = real_killpg
    print(json.dumps({"result": result, "calls": calls}))
    '''

    {output, 0} =
      System.cmd(
        "python3",
        ["-B", "-c", program, Path.join(root, "scripts/check/offline.py"), root],
        stderr_to_stdout: true,
        cd: @project_root
      )

    result = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
    stage = result["result"]
    assert result["calls"] == ["SIGTERM", "SIGKILL"]
    assert stage["exit_code"] == 124
    assert is_integer(stage["duration_ms"])
    assert stage["cleanup"]["status"] == "failed"
    assert stage["cleanup"]["leader_reaped"] == true

    assert stage["cleanup"]["signals"]
           |> Enum.any?(
             &(&1["scope"] == "direct-child" and &1["signal"] == "SIGKILL" and
                 &1["status"] == "sent")
           )

    assert stage["cleanup"]["reason"] =~ "process-group SIGTERM failed"
    assert stage["cleanup"]["reason"] =~ "process-group SIGKILL failed"
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
