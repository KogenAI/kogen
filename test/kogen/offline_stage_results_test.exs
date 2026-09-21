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
end
