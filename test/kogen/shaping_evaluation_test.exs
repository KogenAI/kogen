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

  test "offline rehearsal exercises the maintained driver without provider access" do
    rehearsal = Path.join(@support, "driver_rehearsal_test.py")

    {output, status} =
      System.cmd("python3", ["-B", rehearsal], stderr_to_stdout: true, env: parser_env())

    assert status == 0, output
    assert output =~ "Ran "
    assert output =~ "OK"
  end
end
