defmodule Kogen.OfflineStageResultsTest do
  use ExUnit.Case, async: true
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
        stderr_to_stdout: true
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
        stderr_to_stdout: true
      )

    assert %{"invocation" => "fresh", "schema_version" => 1, "stages" => []} =
             receipt |> File.read!() |> Jason.decode!()
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
        stderr_to_stdout: true
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
        stderr_to_stdout: true
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
        stderr_to_stdout: true
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
        stderr_to_stdout: true
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
        stderr_to_stdout: true
      )

    frame = output |> String.trim() |> Jason.decode!()
    assert frame["stage"] == "test"
    assert frame["test_id"] == "test/kogen/wrapper_test.exs:9"

    assert frame["assertion"] ==
             "pty success: terminal probe failed: [Errno 9] Bad file descriptor"
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
        stderr_to_stdout: true
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
        stderr_to_stdout: true
      )

    assert [tag, json] = String.split(String.trim(output), "\t", parts: 2)
    assert tag == "KOGEN_FAILURE_SIGNATURE"
    frame = Jason.decode!(json)
    assert frame["stage"] == "check"
    assert frame["test_id"] == "test/kogen/some_test.exs:42"
    assert frame["assertion"] == "Assertion with == failed"
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
        stderr_to_stdout: true
      )

    result = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
    assert result["ok"] == nil
    frame = Jason.decode!(result["bad"])
    assert frame["test_id"] == "f.exs:1"
    assert frame["assertion"] == "boom"
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
