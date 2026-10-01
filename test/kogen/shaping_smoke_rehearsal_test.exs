Code.require_file("../support/shaping_evaluation/rehearsal_fixture.ex", __DIR__)
Code.require_file("../support/shaping_evaluation/route_runner.ex", __DIR__)

defmodule Kogen.ShapingSmokeRehearsalTest do
  @moduledoc """
  Offline rehearsal for the headless-flow smoke case (`driver.py --smoke`): the
  real driver `run_smoke/1` -> `setup_fixture/2` -> `drive/4` path runs against
  the real `mix kogen.shape` engine, the real Stop hook and the real
  deterministic audit in a compiled fixture. Its disposable product proof is
  a separate small test that calls the named greeting producer; contract
  controls reject a missing producer, literal-only test, missing cited facts,
  and contradictory scope. Only the provider
  (`test/support/fake_shaping_controller`), the Auditor and the Jev transport
  are faked. Each Python method runs as its own test: the correct control on both
  routes, and wrong controls (a missing scripted answer that must fail fast,
  missing feedback delivery, feedback suppressed while repair remains,
  and an `expect` spawn).
  """
  use Kogen.IsolatedCase, async: true

  alias Kogen.ShapingEvaluation.RehearsalFixture
  alias Kogen.ShapingEvaluation.RouteRunner

  test "a Codex smoke failure still runs and records Claude independently" do
    route_results =
      RouteRunner.run(~w(codex claude), fn
        "codex" ->
          raise "scripted Codex route failure"

        "claude" ->
          send(self(), :claude_route_ran)
          [%{"path" => "claude/evidence.json"}]
      end)

    assert_receive :claude_route_ran

    assert [
             {:error, "codex", %{"message" => "scripted Codex route failure"}},
             {:ok, "claude", [%{"path" => "claude/evidence.json"}]}
           ] = route_results
  end

  @support Path.expand("../support/shaping_evaluation", __DIR__)
  @rehearsal Path.join(@support, "driver_smoke_rehearsal_test.py")
  @feedback_rehearsal Path.join(@support, "feedback_delivery_test.py")

  @methods ~r/^    def (test_\w+)\(/m
           |> Regex.scan(File.read!(@rehearsal), capture: :all_but_first)
           |> List.flatten()

  test "the smoke rehearsal has the correct control and the wrong controls" do
    assert "test_smoke_rehearsal_dispatches_real_functions_and_manifests_once" in @methods
    assert "test_smoke_wrong_control_missing_scripted_answer_fires_fail_fast" in @methods
    assert "test_smoke_wrong_control_missing_feedback_delivery_fails" in @methods
    assert "test_smoke_setup_copy_exception_cleans_only_the_owned_partial_fixture" in @methods
    assert "test_smoke_path_accepts_three_authored_messages_and_binds_each" in @methods
    assert "test_smoke_path_three_message_wrong_control_requires_each_answer_record" in @methods
    assert "test_smoke_wrong_control_expect_spawn_fails_the_rehearsal" in @methods

    assert "test_smoke_correct_control_first_answer_is_steered_and_recorded_in_the_original_turn" in @methods

    assert "test_smoke_wrong_control_steering_disabled_first_answer_recorded_only_on_fallback_resume" in @methods

    assert "test_smoke_wrong_control_offer_exists_but_recording_only_in_a_later_turn" in @methods

    assert "test_smoke_correct_control_audit_feedback_is_delivered_to_a_root_launch_before_the_repair" in @methods

    assert "test_smoke_wrong_control_feedback_suppressed_but_repair_and_report_progression_remain" in @methods

    assert "test_runtime_absent_prepare_succeeds_but_ordinary_execution_refuses" in @methods
    assert "test_parser_dependency_and_lifetime_controls_have_no_provider_dispatch" in @methods

    assert "test_rehearsal_fixture_runs_real_audit_and_verification_plan_on_repaired_drafts" in @methods

    assert length(@methods) == length(Enum.uniq(@methods))
  end

  @tag timeout: 600_000
  test "offline delivered-feedback receipt controls" do
    {output, status} = System.cmd("python3", ["-B", @feedback_rehearsal], stderr_to_stdout: true)

    assert status == 0, output
    assert output =~ "Ran 4 tests"
    assert output =~ "OK"
  end

  for method <- @methods do
    @tag timeout: 600_000
    test "offline smoke rehearsal #{method}" do
      fixture = RehearsalFixture.create!()
      on_exit(fn -> RehearsalFixture.cleanup!(fixture) end)
      {_root, handoff} = fixture

      {output, status} =
        System.cmd(
          "python3",
          ["-B", @rehearsal, "DriverSmokeRehearsalTest.#{unquote(method)}"],
          stderr_to_stdout: true,
          env: python_env(handoff)
        )

      assert status == 0, output
      assert output =~ "Ran 1 test"
      assert output =~ "OK"
      refute output =~ "skipped", "the rehearsal must not skip: #{output}"
    end
  end

  test "K5 the smoke Python runners drop a Build session's KOGEN_ROLE and KOGEN_HARNESS_HOME" do
    previous = %{
      "KOGEN_ROLE" => System.get_env("KOGEN_ROLE"),
      "KOGEN_HARNESS_HOME" => System.get_env("KOGEN_HARNESS_HOME")
    }

    on_exit(fn ->
      for {name, nil} <- previous, do: System.delete_env(name)
      for {name, value} when is_binary(value) <- previous, do: System.put_env(name, value)
    end)

    System.put_env("KOGEN_ROLE", "developer")
    System.put_env("KOGEN_HARNESS_HOME", "/tmp/kogen-hostile-home")

    {output, 0} =
      System.cmd(
        "python3",
        [
          "-B",
          "-c",
          "import os; print(os.environ.get('KOGEN_ROLE'), os.environ.get('KOGEN_HARNESS_HOME'))"
        ],
        env: python_env(nil)
      )

    assert output == "None None\n"
  end

  # The Python child never inherits a managed role or harness home, and its
  # parser subprocess gets this VM's exact compiled paths (the isolated child
  # has an empty private MIX_BUILD_PATH).
  defp python_env(handoff) do
    base = [{"KOGEN_ROLE", nil}, {"KOGEN_HARNESS_HOME", nil}]

    if handoff do
      base ++
        [
          {RehearsalFixture.handoff_env(), handoff},
          {"KOGEN_SHAPING_EVALUATION_ELIXIR_CODE_PATHS", parser_code_paths()}
        ]
    else
      base
    end
  end

  defp parser_code_paths do
    :code.get_path()
    |> Enum.map(&List.to_string/1)
    |> Enum.filter(
      &(Path.type(&1) == :absolute and Path.basename(&1) == "ebin" and File.dir?(&1))
    )
    |> Enum.uniq()
    |> Enum.sort()
    |> Jason.encode!()
  end
end
