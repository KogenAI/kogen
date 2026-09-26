defmodule Kogen.ShapingEvaluationTest do
  use Kogen.IsolatedCase, async: true

  @support Path.expand("../support/shaping_evaluation", __DIR__)
  defp parser_env do
    paths =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.filter(&(Path.type(&1) == :absolute))
      |> Enum.uniq()

    [{"KOGEN_SHAPING_EVALUATION_ELIXIR_CODE_PATHS", Jason.encode!(paths)}]
  end

  test "compact five-case evaluation uses local CLI facts and preserves the native boundary" do
    driver = File.read!(Path.join(@support, "driver.py"))
    facts = Jason.decode!(File.read!(Path.join(@support, "compact-fixtures-v2/facts.json")))

    assert driver =~ "MAX_SECONDS = 600"
    assert driver =~ "SUITE_SECONDS = MAX_SECONDS + 120"
    assert driver =~ "deadline = monotonic_now() + SUITE_SECONDS"
    assert driver =~ "setup_continuation_seed()"
    assert driver =~ "KOGEN_SHAPING_EVALUATION_SUITE_BARRIER"
    assert driver =~ "shape_transport.exp"
    assert driver =~ "resume_transport.exp"
    assert facts["csv"]["feature"] =~ "normalize INPUT OUTPUT"
    assert facts["calendar"]["feature"] =~ "slots CONNECTION"
    refute driver =~ "CSV viewer"
    refute driver =~ "booking service"
  end

  test "compact fixture inputs are local, frozen and source-bound" do
    fixture = Path.join(@support, "compact-fixtures-v2")
    protocol = Jason.decode!(File.read!(Path.join(fixture, "protocol.json")))

    assert protocol["source_hashes"]["facts.json"]

    for name <-
          ~w(facts.json protocol.json reader_control.py calendar_adapter.py capability-seed.json) do
      assert File.regular?(Path.join(fixture, name))
    end
  end

  test "native binding controls reject ambiguous, reused, and interrupted turns" do
    {output, status} =
      System.cmd("python3", ["-B", Path.join(@support, "native_binding_test.py")],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "OK"
  end

  test "rollout trigger accepts the string paths returned by session discovery" do
    script = """
    import os, runpy, sys, tempfile
    from pathlib import Path
    with tempfile.TemporaryDirectory() as directory:
        os.environ["KOGEN_SHAPING_EVALUATION_RUNTIME"] = directory
        contains = runpy.run_path(sys.argv[1])["rollout_contains"]
        rollout = Path(directory) / "rollout.jsonl"
        rollout.write_text("Observed UTF-8 BOM discrepancy")
        assert contains(str(rollout), "bom")
        assert contains(rollout, "BOM")
        assert not contains(str(rollout), "invented evidence")
        assert not contains(str(Path(directory) / "missing.jsonl"), "bom")
        print("rollout path controls: ok")
    """

    {output, status} =
      System.cmd("python3", ["-B", "-c", script, Path.join(@support, "driver.py")],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "rollout path controls: ok"
  end

  test "Draft provenance projection parses supported YAML forms and rejects partial data" do
    {output, status} =
      System.cmd("python3", ["-B", Path.join(@support, "driver_draft_state_test.py")],
        stderr_to_stdout: true,
        env: parser_env()
      )

    assert status == 0, output
    assert output =~ "OK"
  end

  # driver_rehearsal_test.py spawns the real YAML parser dozens of times.
  # Under the full suite's parallel load one run of every method exceeded
  # ExUnit's 60 s budget, so its two heaviest methods run as their own
  # tests. Together the three tests run every method exactly once; the
  # split is derived from the file, so a new method lands in the first.
  @heavy_rehearsals [
    "test_composed_suite_uses_main_routes_and_real_drive_before_manifest",
    "test_valid_yaml_with_null_first_capture_stops_real_suite_before_later_dispatch"
  ]

  defp rehearsal_methods do
    ~r/^    def (test_\w+)\(/m
    |> Regex.scan(File.read!(Path.join(@support, "driver_rehearsal_test.py")),
      capture: :all_but_first
    )
    |> List.flatten()
  end

  defp run_rehearsal!(methods) do
    rehearsal = Path.join(@support, "driver_rehearsal_test.py")
    names = Enum.map(methods, &"DriverRehearsalTest.#{&1}")

    {output, status} =
      System.cmd("python3", ["-B", rehearsal | names], stderr_to_stdout: true, env: parser_env())

    assert status == 0, output
    assert output =~ "Ran #{length(methods)} test"
    assert output =~ "OK"
  end

  test "offline rehearsal exercises the maintained driver without provider access" do
    methods = rehearsal_methods()
    assert Enum.all?(@heavy_rehearsals, &(&1 in methods))
    assert length(methods) == length(Enum.uniq(methods))
    run_rehearsal!(methods -- @heavy_rehearsals)
  end

  test "offline rehearsal composes the real suite through main routes before the manifest" do
    run_rehearsal!(["test_composed_suite_uses_main_routes_and_real_drive_before_manifest"])
  end

  test "offline rehearsal stops the real suite on a null first capture before later dispatch" do
    run_rehearsal!([
      "test_valid_yaml_with_null_first_capture_stops_real_suite_before_later_dispatch"
    ])
  end

  test "driver-turn-end-replay replays real retained rollouts through the driver's own fail-fast decision" do
    replay = Path.join(@support, "driver_turn_end_replay_test.py")

    {output, status} = System.cmd("python3", ["-B", replay], stderr_to_stdout: true)

    assert status == 0, output
    assert output =~ "Ran "
    assert output =~ "OK"
  end
end
