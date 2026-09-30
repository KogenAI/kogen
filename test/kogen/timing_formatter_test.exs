defmodule Kogen.TimingFormatterTest do
  use ExUnit.Case, async: true

  alias Kogen.IsolationGuard
  alias Kogen.TimingFormatter

  @project_root Path.expand("../..", __DIR__)

  test "excluded and skipped tests are not failures; failed and invalid tests are" do
    assert TimingFormatter.status(nil) == "passed"
    assert TimingFormatter.status({:excluded, "unconfined"}) == "excluded"
    assert TimingFormatter.status({:skipped, "skipped"}) == "skipped"
    assert TimingFormatter.status({:failed, []}) == "failed"
    assert TimingFormatter.status({:invalid, SomeModule}) == "failed"
  end

  test "the admission proof accepts excluded and skipped events and rejects failed and invalid ones" do
    program = ~S'''
    import importlib.util, json, sys
    spec = importlib.util.spec_from_file_location("offline", sys.argv[1])
    offline = importlib.util.module_from_spec(spec); spec.loader.exec_module(offline)
    manifest = {"schema_version": 1, "exclude": ["live"], "tests": []}
    def event(name, status):
        return {"file": "test/kogen/x_test.exs", "module": "X", "name": name,
                "parameters": {}, "status": status}
    def failures(statuses):
        events = [event(f"t{i}", s) for i, s in enumerate(statuses)]
        found = offline.validate_admission_proof(manifest, events, None, None)
        return [f for f in found if "did not pass" in f or "no passing test" in f]
    print(json.dumps({
        "mixed": failures(["passed", "excluded", "skipped"]),
        "failed": failures(["passed", "excluded", "failed"]),
        "none_ran": failures(["excluded", "skipped"]),
    }))
    '''

    {output, 0} =
      System.cmd(
        "python3",
        ["-B", "-c", program, Path.join(@project_root, "scripts/check/offline.py")],
        stderr_to_stdout: true,
        cd: @project_root
      )

    result = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
    assert result["mixed"] == []
    assert [failed] = result["failed"]
    assert failed =~ "1 Candidate non-live test(s) did not pass"
    assert [_] = result["none_ran"]
  end

  describe "runtime isolation guard" do
    defp snap(cwd, env), do: %{cwd: cwd, env: Map.new(env)}

    test "an unchanged cwd and environment is silent" do
      base = snap("/a", [{"KOGEN_X", "1"}])
      guard = %{IsolationGuard.new() | baseline: base}
      guard = IsolationGuard.check(guard, nil, base)
      assert IsolationGuard.violations(guard) == []
    end

    test "a changed cwd or env names the tests in flight" do
      base = snap("/a", [{"KOGEN_X", "1"}, {"HOME", "/h"}])
      guard = %{IsolationGuard.new() | baseline: base}
      guard = %{guard | inflight: MapSet.new(["Some.Module test one"])}

      changed = snap("/b", [{"KOGEN_X", "2"}, {"MIX_ENV", "dev"}])
      guard = IsolationGuard.check(guard, "Some.Module test two", changed)

      assert [message] = IsolationGuard.violations(guard)
      assert message =~ "cwd /a -> /b"
      assert message =~ ~s(env KOGEN_X "1" -> "2")
      assert message =~ ~s(env HOME "/h" -> nil)
      assert message =~ ~s(env MIX_ENV nil -> "dev")
      assert message =~ "Some.Module test one"
      assert message =~ "Some.Module test two"

      # Re-baselined: the same change is not reported twice.
      guard = IsolationGuard.check(guard, nil, changed)
      assert length(IsolationGuard.violations(guard)) == 1
    end

    test "snapshot covers only the guarded variables" do
      %{env: env, cwd: cwd} = IsolationGuard.snapshot()
      assert cwd == File.cwd!()

      assert Enum.all?(Map.keys(env), fn name ->
               name in ~w(HOME CODEX_HOME CLAUDE_CONFIG_DIR) or
                 String.starts_with?(name, "KOGEN_") or String.starts_with?(name, "MIX_")
             end)

      refute Map.has_key?(env, "PATH")
    end
  end
end
