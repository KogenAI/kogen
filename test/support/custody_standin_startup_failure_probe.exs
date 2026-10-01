# Run one real ExUnit cleanup failure path in a child BEAM. The parent test
# validates the artifact after ExUnit.run/0 because ExUnit may suppress an
# on_exit callback exception when the test itself already failed.

[mode, control, out] = System.argv()
project_root = Path.expand("../..", __DIR__)

unless mode in ["startup", "assertion_abort", "assertion_abort_negative_control"] do
  raise "unknown custody cleanup probe mode: #{inspect(mode)}"
end

System.put_env("KOGEN_TEST_ROOT", project_root)
System.put_env("KOGEN_CUSTODY_FAILURE_PROBE", "1")
System.put_env("KOGEN_CUSTODY_PROBE_MODE", mode)
System.put_env("KOGEN_CUSTODY_CONTROL", control)
System.put_env("KOGEN_CUSTODY_OUT", out)

artifact_name =
  if mode == "startup",
    do: "custody-startup-readiness-failure-probe.json",
    else: "custody-assertion-abort-cleanup-probe.json"

artifact_path = Path.join(out, artifact_name)
System.put_env("KOGEN_CUSTODY_PROBE_ARTIFACT", artifact_path)

if mode == "assertion_abort_negative_control" do
  System.put_env("KOGEN_CUSTODY_PROBE_INJECT_CALLBACK_FAILURE", "1")
end

ExUnit.start(autorun: false)

include =
  case mode do
    "startup" -> [startup_cleanup_probe: true]
    "assertion_abort_negative_control" -> [cleanup_callback_failure_probe: true]
    _ -> [assertion_abort_cleanup_probe: true]
  end

ExUnit.configure(exclude: [:test], include: include)
Code.require_file(Path.expand("../kogen/process_custody_test.exs", __DIR__))

result = ExUnit.run()
executed = result.total - result.excluded

if executed != 1 or result.failures < 1 do
  IO.puts("CUSTODY_PROBE_EXPECTED_ASSERTION_FAILURE_MISSING=#{inspect(result)}")
  System.halt(1)
end

output = File.read!(artifact_path) |> Jason.decode!()

validate_cleanup = fn expected_stage ->
  case output["cleanup"] do
    %{
      "stage" => ^expected_stage,
      "controller_stopped" => true,
      "lock_absent" => true,
      "provider_processes_stopped" => true,
      "port_closed" => true,
      "errors" => []
    } ->
      :ok

    other ->
      IO.puts("CUSTODY_PROBE_CLEANUP_ARTIFACT_INVALID=#{inspect(other)}")
      System.halt(1)
  end
end

case mode do
  "startup" ->
    unless output["cleanup"] do
      IO.puts("CUSTODY_STARTUP_FAILURE_PROBE_ARTIFACT_MISSING")
      System.halt(1)
    end

    validate_cleanup.("startup_failure_inline_cleanup_complete")
    IO.puts("CUSTODY_STARTUP_FAILURE_PROBE_PASS")

  "assertion_abort" ->
    unless output["probe"] == "assertion-abort-owned-process-cleanup" and
             output["stage"] == "live_owned_processes_before_assertion_abort" and
             is_map(output["live"]) and output["live"]["pipe_open"] == true and
             output["live"]["group_count"] > 0 do
      IO.puts("CUSTODY_ASSERTION_ABORT_PROBE_LIVE_STAGE_MISSING=#{inspect(output)}")
      System.halt(1)
    end

    validate_cleanup.("assertion_abort_on_exit_cleanup_complete")
    IO.puts("CUSTODY_ASSERTION_ABORT_PROBE_PASS")

  "assertion_abort_negative_control" ->
    unless output["probe"] == "assertion-abort-owned-process-cleanup" and
             output["stage"] == "live_owned_processes_before_assertion_abort" and
             output["injected_callback_failure"] == true do
      IO.puts(
        "CUSTODY_ASSERTION_ABORT_PROBE_NEGATIVE_CONTROL_ARTIFACT_INVALID=#{inspect(output)}"
      )

      System.halt(1)
    end

    validate_cleanup.("assertion_abort_on_exit_cleanup_complete")
    IO.puts("CUSTODY_ASSERTION_ABORT_PROBE_CALLBACK_FAILURE_CAPTURED")
    System.halt(42)
end
