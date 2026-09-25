Code.require_file("../support/route_config.ex", __DIR__)

defmodule Kogen.Codex.CompatibilityTest do
  use Kogen.IsolatedCase, async: true

  alias Kogen.Build.TargetEvidence
  alias Kogen.Codex.Compatibility
  alias Kogen.RouteConfig

  @hostile_discovery %{
    "personal_marker" => false,
    "project_marker" => true,
    "root_receipt" => true,
    "shell_modes" => true,
    "helper_receipt" => true,
    "helper_environment" => true,
    "helper_context" => true,
    "resume_rework" => true,
    "hook_receipt" => true
  }

  @evidence %{
    "shaping" => %{"status" => 0, "marker" => true, "cleanup" => true},
    "developer" => %{"session_id" => "developer-1"},
    "resume" => %{"session_id" => "developer-1"},
    "hostile_discovery" => @hostile_discovery,
    "checks" => [
      %{"session_id" => "developer-1", "status" => "failed"},
      %{"session_id" => "developer-1", "status" => "passed"},
      %{"session_id" => "developer-1", "status" => "passed"}
    ],
    "checks_before_resume" => 2,
    "discovery_controls" => %{"ok" => true},
    "blocked_gate" => true
  }

  test "evidence requires the failed-then-passed Check, exact developer resume, and its fresh Check" do
    assert :ok = Compatibility.verify_evidence(@evidence)

    # No stand-in Reviewer receipt is part of the runner's contract.
    refute Enum.any?(Map.keys(@evidence), &String.contains?(&1, "reviewer"))

    stale = Map.put(@evidence, "checks_before_resume", 3)
    assert {:error, :resume_check_missing} = Compatibility.verify_evidence(stale)

    unrelated =
      Map.update!(stale, "checks", &(&1 ++ [%{"session_id" => "other", "status" => "passed"}]))

    assert {:error, _} = Compatibility.verify_evidence(unrelated)

    failed =
      put_in(
        @evidence,
        ["checks"],
        Enum.take(@evidence["checks"], 2) ++
          [%{"session_id" => "developer-1", "status" => "failed"}]
      )

    assert {:error, _} = Compatibility.verify_evidence(failed)

    uncorrected =
      Map.put(@evidence, "checks", [
        %{"session_id" => "developer-1", "status" => "passed"},
        %{"session_id" => "developer-1", "status" => "passed"}
      ])

    assert {:error, :missing_failed_check_correction_or_resume} =
             Compatibility.verify_evidence(uncorrected)
  end

  test "evidence rejects a missing resume check, a fresh resume, or a missing helper receipt" do
    missing_resume_check =
      Map.merge(@evidence, %{
        "checks" => Enum.take(@evidence["checks"], 2),
        "checks_before_resume" => 2
      })

    assert {:error, _} = Compatibility.verify_evidence(missing_resume_check)

    fresh_resume = put_in(@evidence, ["resume", "session_id"], "developer-2")

    assert {:error, :incomplete_compatibility_evidence} =
             Compatibility.verify_evidence(fresh_resume)

    for key <- Map.keys(@hostile_discovery) do
      broken = update_in(@evidence, ["hostile_discovery", key], &(not &1))
      assert {:error, _} = Compatibility.verify_evidence(broken), key
    end

    for key <- ~w(shaping discovery_controls blocked_gate) do
      assert {:error, _} = Compatibility.verify_evidence(Map.delete(@evidence, key)), key
    end

    refute_shaping = put_in(@evidence, ["shaping", "cleanup"], false)
    assert {:error, _} = Compatibility.verify_evidence(refute_shaping)
  end

  test "failed evidence names environment mismatches" do
    evidence = %{
      "hostile_discovery" => %{"root_receipt" => false, "helper_environment" => false}
    }

    assert {:error, {:compatibility_requirements_failed, failures}} =
             Compatibility.verify_evidence(evidence)

    assert {"root_receipt", :caller_environment_mismatch} in failures
    assert {"helper_environment", :caller_environment_mismatch} in failures
  end

  test "only the bounded wrapper's timed_out receipt classifies a turn as timed out" do
    reason = {:provider_exit, 124, ""}

    assert {:compatibility_turn_timed_out, :launch_developer, ^reason} =
             Compatibility.turn_failure(:launch_developer, reason, %{"timed_out" => true})

    assert {:compatibility_turn, :launch_developer, ^reason} =
             Compatibility.turn_failure(:launch_developer, reason, %{"timed_out" => false})

    assert {:compatibility_turn, :launch_developer, ^reason} =
             Compatibility.turn_failure(:launch_developer, reason, %{})
  end

  test "the owner passes the explicit 240 s per-turn limit to the bounded wrapper" do
    # A deadline far beyond any real turn ensures the computed seconds are
    # capped by, and therefore expose, the owner's own fixed per-turn limit
    # rather than whatever remains before the whole-test deadline.
    far_deadline = System.monotonic_time(:millisecond) + 10 * 60 * 60 * 1000

    assert {:ok, bounded_context} =
             Compatibility.bounded(%{env: [], args: [], executable: "codex-fake"}, far_deadline)

    assert {"KOGEN_BOUNDED_EXEC_TIMEOUT", "240"} in bounded_context.env
    assert List.first(bounded_context.args) =~ "bounded_exec.py"
  end

  test "bounded_exec.py's own default per-turn timeout is unchanged at 240 seconds" do
    path = Application.app_dir(:kogen, "priv/kogen/codex/compatibility/bounded_exec.py")
    source = File.read!(path)

    assert source =~ ~r/seconds\(\s*"KOGEN_BOUNDED_EXEC_TIMEOUT"\s*,\s*240\s*\)/
  end

  test "the runner launches no Reviewer-role turn at all" do
    source =
      Compatibility.module_info(:compile)
      |> Keyword.fetch!(:source)
      |> List.to_string()
      |> File.read!()

    refute source =~ ~r/launch_reviewer|resume_reviewer/
    refute source =~ ~r/KOGEN_ROLE["'\s]*,?\s*["']reviewer["']/i
    refute source =~ ~r/:reviewer\b/

    # Only these two Developer-role functions are ever dispatched through the
    # harness; a scripted stand-in Reviewer turn would add a third.
    invoked = Regex.scan(~r/invoke_harness\(\s*:(\w+)/, source) |> Enum.map(&Enum.at(&1, 1))
    assert Enum.uniq(invoked) |> Enum.sort() == ["launch_developer", "resume_developer"]
  end

  test "a timed_out attempt is rerun once in a fresh fixture and both attempts are retained" do
    %{root: root, config: config} = setup_attempts("rerun")
    clock = fake_clock()

    attempt = fn number, _deadline ->
      advance(clock, 200_000)
      {:ok, fixture, evidence, _discovery} = Compatibility.prepare_fixture(root, config)
      write_process_receipt(fixture, "launch_developer", "thread-#{number}", number == 1)

      if number == 1 do
        reason = {:compatibility_turn_timed_out, :launch_developer, {:provider_exit, 124, ""}}
        File.write!(evidence, Jason.encode!(%{"status" => "failed"}))
        {:error, {:compatibility_failed, reason, evidence}}
      else
        File.write!(evidence, Jason.encode!(%{"status" => "passed"}))
        {:ok, evidence}
      end
    end

    assert {:ok, %{summary: summary_path, locator: locator}} =
             Compatibility.run_attempts(attempt, root: root, clock: reader(clock))

    summary = Jason.decode!(File.read!(Path.join(root, summary_path)))
    assert summary["result"] == "ok"
    assert summary["retry"] == %{"started" => true}
    assert summary["turn_timeout_seconds"] == 240
    assert summary["deadline_ms"] == 900_000
    assert summary["elapsed_ms"] == 400_000

    assert [first, second] = summary["attempts"]

    assert {first["number"], first["class"], second["number"], second["class"]} ==
             {1, "timed_out", 2, "passed"}

    assert first["elapsed_ms"] == 200_000 and second["elapsed_ms"] == 200_000
    assert first["reason"] =~ "compatibility_turn_timed_out"
    assert first["fixture"] != second["fixture"]
    assert File.dir?(first["fixture"]) and File.dir?(second["fixture"])

    assert [%{"operation" => "launch_developer", "session_id" => "thread-1", "timed_out" => true}] =
             first["sessions"]

    assert [%{"session_id" => "thread-2", "timed_out" => false, "cleanup" => true}] =
             second["sessions"]

    assert first["cleanup"]["ok"] and second["cleanup"]["ok"]
    assert_manifest(root, locator, 3)
  end

  test "a rerun passes only if the second attempt fully passes" do
    %{root: root, config: config} = setup_attempts("second-fails")
    clock = fake_clock()

    attempt = fn number, _deadline ->
      advance(clock, 100_000)
      {:ok, _fixture, evidence, _discovery} = Compatibility.prepare_fixture(root, config)
      File.write!(evidence, "{}")

      reason =
        if number == 1,
          do: {:compatibility_turn_timed_out, :resume_developer, {:provider_exit, 124, ""}},
          else: :resume_check_missing

      {:error, {:compatibility_failed, reason, evidence}}
    end

    assert {:error, %{summary: summary_path}} =
             Compatibility.run_attempts(attempt, root: root, clock: reader(clock))

    summary = Jason.decode!(File.read!(Path.join(root, summary_path)))
    assert summary["result"] == "error"
    assert Enum.map(summary["attempts"], & &1["class"]) == ["timed_out", "failed"]
  end

  test "no rerun starts when a typical run no longer fits before the deadline" do
    %{root: root, config: config} = setup_attempts("no-time")
    clock = fake_clock()
    parent = self()

    attempt = fn number, deadline ->
      send(parent, {:attempt, number, deadline})
      # 900 s ceiling minus the 60 s reserve leaves 840 s; after 600 s only 240 s
      # remain, less than the 300 s typical run.
      advance(clock, 600_000)
      {:ok, _fixture, evidence, _discovery} = Compatibility.prepare_fixture(root, config)
      File.write!(evidence, "{}")
      reason = {:interactive_shaping_failed, %{}, %{status: :timed_out}}
      {:error, {:compatibility_failed, reason, evidence}}
    end

    assert {:error, %{summary: summary_path, locator: locator}} =
             Compatibility.run_attempts(attempt, root: root, clock: reader(clock))

    assert_received {:attempt, 1, 840_000}
    refute_received {:attempt, 2, _}

    summary = Jason.decode!(File.read!(Path.join(root, summary_path)))
    assert summary["retry"] == %{"started" => false, "reason" => "no_retry_fitted"}
    assert [%{"class" => "timed_out"}] = summary["attempts"]
    assert_manifest(root, locator, 2)
  end

  test "failures other than timed_out are never rerun" do
    %{root: root, config: config} = setup_attempts("other-class")

    for reason <- [
          {:compatibility_turn, :launch_developer, {:provider_exit, 124, ""}},
          {:compatibility_turn, :launch_developer, {:provider_exit, 1, ""}},
          {:interactive_shaping_failed, %{}, %{status: :provider_failed}},
          {:compatibility_requirements_failed, [{"root_receipt", :caller_environment_mismatch}]},
          :resume_check_missing
        ] do
      parent = self()

      attempt = fn number, _deadline ->
        send(parent, {:attempt, number})
        {:ok, _fixture, evidence, _discovery} = Compatibility.prepare_fixture(root, config)
        File.write!(evidence, "{}")
        {:error, {:compatibility_failed, reason, evidence}}
      end

      assert {:error, %{summary: summary_path}} = Compatibility.run_attempts(attempt, root: root)
      assert_received {:attempt, 1}
      refute_received {:attempt, 2}

      summary = Jason.decode!(File.read!(Path.join(root, summary_path)))
      assert summary["retry"] == %{"started" => false, "reason" => "not_timed_out"}
      assert [%{"class" => "failed"}] = summary["attempts"]
    end

    attempt = fn _number, _deadline -> {:error, :invalid_runtime} end
    assert {:error, %{summary: summary_path}} = Compatibility.run_attempts(attempt, root: root)
    summary = Jason.decode!(File.read!(Path.join(root, summary_path)))
    assert [%{"class" => "failed", "fixture" => nil, "evidence" => nil}] = summary["attempts"]
  end

  test "a first passing attempt is not rerun" do
    %{root: root, config: config} = setup_attempts("pass")
    parent = self()

    attempt = fn number, _deadline ->
      send(parent, {:attempt, number})
      {:ok, _fixture, evidence, _discovery} = Compatibility.prepare_fixture(root, config)
      File.write!(evidence, "{}")
      {:ok, evidence}
    end

    assert {:ok, %{summary: summary_path}} = Compatibility.run_attempts(attempt, root: root)
    refute_received {:attempt, 2}
    summary = Jason.decode!(File.read!(Path.join(root, summary_path)))
    assert summary["retry"] == %{"started" => false, "reason" => "passed"}
  end

  @tag target_evidence: :required
  @tag :live
  @tag timeout: 900_000
  test "selected authenticated managed runtime passes the bounded compatibility runner" do
    config = RouteConfig.codex_route!()
    {:ok, runtime} = Kogen.Codex.installed()
    {:ok, scope} = Kogen.Codex.effective_scope(File.cwd!())
    assert :ok = Kogen.Codex.require_login(runtime, scope, File.cwd!())

    {status, %{summary: summary, locator: locator}} =
      Compatibility.run_bounded(runtime, scope, config)

    # Build retains this one manifest, and both attempts' evidence, whether the
    # runner passed or failed.
    IO.write("\nKOGEN_TARGET_EVIDENCE_MANIFEST\t" <> Jason.encode!(locator) <> "\n")

    assert status == :ok,
           "compatibility runner failed; summary: #{summary}\n#{File.read!(summary)}"
  end

  defp setup_attempts(name) do
    base =
      Path.join(
        System.tmp_dir!(),
        "compatibility-attempts-#{name}-#{System.unique_integer([:positive])}"
      )

    root = Path.join(base, "repository")
    File.mkdir_p!(Path.join(root, ".codex/hooks"))
    source = File.cwd!()

    for path <-
          ~w(README.md .codex/hooks.json .codex/hooks/check.sh .codex/hooks/stop_runner.py .codex/hooks/verification_policy.py .codex/hooks/environment.py) do
      File.cp!(Path.join(source, path), Path.join(root, path))
    end

    System.put_env("KOGEN_CODEX_ROOT", Path.join(base, "codex"))
    on_exit(fn -> File.rm_rf!(base) end)
    %{root: root, config: RouteConfig.codex_route!()}
  end

  defp write_process_receipt(fixture, operation, session_id, timed_out) do
    File.write!(
      Path.join(fixture, ".kogen/runtime/process-#{operation}-7.json"),
      Jason.encode!(%{
        "native_session_id" => session_id,
        "native_exit" => if(timed_out, do: nil, else: 0),
        "timed_out" => timed_out,
        "cleanup" => %{"ok" => true}
      })
    )
  end

  defp assert_manifest(root, locator, count) do
    manifest_bytes = File.read!(Path.join(root, locator["manifest_path"]))
    assert sha256(manifest_bytes) == locator["sha256"]
    manifest = Jason.decode!(manifest_bytes)
    assert manifest["schema_version"] == 1
    assert length(manifest["required_evidence"]) == count

    for %{"path" => path, "sha256" => digest} <- manifest["required_evidence"] do
      assert Path.type(path) == :relative
      assert sha256(File.read!(Path.join(root, path))) == digest
    end

    frame = "KOGEN_TARGET_EVIDENCE_MANIFEST\t" <> Jason.encode!(locator) <> "\n"

    assert {:ok, %{"required_evidence" => retained}} =
             TargetEvidence.capture(frame, "live-native", "attempt", root)

    assert length(retained) == count
  end

  defp fake_clock do
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    clock
  end

  defp advance(clock, milliseconds), do: Agent.update(clock, &(&1 + milliseconds))
  defp reader(clock), do: fn -> Agent.get(clock, & &1) end
  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
