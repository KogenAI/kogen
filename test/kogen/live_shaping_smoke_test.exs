Code.require_file("../support/shaping_evaluation/route_runner.ex", __DIR__)

defmodule Kogen.LiveShapingSmokeTest do
  @moduledoc """
  Public, provider-backed headless Shaping smoke. On the `codex` and the
  `claude` route, the `headless-flow` case runs the Candidate's own
  `mix kogen.shape` engine through `driver.py --smoke`: a detached real turn
  writes a question and keeps working, an answer sent mid-turn is recorded by
  the root session, a real audit finding reaches the Shaping Controller and is
  repaired, a message after the turn resumes the same provider session, and
  the session reaches `ready` with a current report and a presentation.

  Each route must reach `ready` within 20 minutes of its start (the driver's
  bound, re-checked by `integrity.py --smoke`), and the whole target within 45
  minutes. The owner emits one evidence manifest locator covering both routes.
  """
  use Kogen.IsolatedCase, async: true

  alias Kogen.ShapingEvaluation.RouteRunner

  @project_root Path.expand("../..", __DIR__)
  @routes ~w(codex claude)
  @route_seconds 20 * 60
  @target_seconds 45 * 60
  @fixture_root_env "KOGEN_SHAPING_EVALUATION_FIXTURE_ROOT"

  @moduletag :live
  @tag isolated_required_output_prefix: "KOGEN_TARGET_EVIDENCE_MANIFEST"
  @tag isolated_required_output_manifest: true
  # The 45-minute target bound, plus bounded copy/preflight/cleanup overhead.
  @moduletag timeout: (@target_seconds + 5 * 60) * 1000

  test "headless-flow reaches ready on the codex and claude routes with repaired audit feedback, one provider session and a presentation" do
    root = @project_root
    support = Path.join(root, "test/support/shaping_evaluation")

    target_runtime =
      Path.join(
        root,
        ".kogen/runtime/shaping-smoke-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(target_runtime)
    started = System.monotonic_time(:second)

    route_results =
      RouteRunner.run(@routes, fn route ->
        route_entries(root, support, Path.join(target_runtime, route), route)
      end)

    route_results =
      Enum.map(route_results, fn
        {:ok, _route, _entries} = success ->
          success

        {:error, route, failure} ->
          runtime = Path.join(target_runtime, route)
          File.mkdir_p!(runtime)
          path = Path.join(runtime, "route-failure.json")
          File.write!(path, Jason.encode!(failure, pretty: true) <> "\n")

          {:error, route, failure,
           %{"path" => Path.relative_to(path, root), "sha256" => sha256(path)}}
      end)

    entries =
      Enum.flat_map(route_results, fn
        {:ok, _route, route_file_entries} -> route_file_entries
        {:error, _route, _failure, entry} -> [entry]
      end)

    elapsed = System.monotonic_time(:second) - started

    assert elapsed <= @target_seconds,
           "the smoke target took #{elapsed}s, over its #{@target_seconds}s bound; retained evidence: #{target_runtime}"

    manifest = Path.join(target_runtime, "evidence-manifest.json")

    File.write!(
      manifest,
      Jason.encode!(%{"schema_version" => 1, "required_evidence" => entries}, pretty: true) <>
        "\n"
    )

    locator = %{
      "manifest_path" => Path.relative_to(manifest, root),
      "sha256" => sha256(manifest)
    }

    # Build extracts this one record from the target's complete output: both
    # routes' validated evidence, without private streams or detailed receipts.
    IO.write("\nKOGEN_TARGET_EVIDENCE_MANIFEST\t" <> Jason.encode!(locator) <> "\n")

    assert Enum.all?(route_results, &match?({:ok, _, _}, &1)),
           "one or more headless routes failed independently; retained outcomes: #{inspect(route_results)}"
  end

  defp route_entries(root, support, runtime, route) do
    File.mkdir_p!(runtime)
    route_started = System.monotonic_time(:second)

    fixture_root =
      Path.join(
        System.tmp_dir!(),
        "kogen-shaping-smoke-fixtures-#{System.pid()}-#{route}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(fixture_root)

    {output, status} =
      try do
        System.cmd(
          "python3",
          ["-B", Path.join(support, "driver.py"), "--smoke", "--harness", route],
          cd: root,
          env: [
            # IsolatedCase supplies offline Jev defaults; paid dispatch must use
            # the real Keychain and transport, never that replay vocabulary.
            {"KOGEN_JEV_TRANSPORT", nil},
            {"KOGEN_JEV_SECURITY", nil},
            {"KOGEN_SHAPING_EVALUATION_RUNTIME", runtime},
            {@fixture_root_env, fixture_root},
            {"KOGEN_SHAPING_EVALUATION_ELIXIR_CODE_PATHS", parser_code_paths()}
          ],
          stderr_to_stdout: true
        )
      after
        # This path is uniquely created above. Remove only the empty parent;
        # a retained child fixture stays available for failure diagnosis.
        cleanup_external_fixture_root(fixture_root, runtime, route)
      end

    if status == 0 do
      refute File.exists?(fixture_root),
             "#{route} left fixture data outside the run evidence directory: #{fixture_root}"
    end

    route_elapsed = System.monotonic_time(:second) - route_started

    frames =
      Regex.scan(~r/^KOGEN_TARGET_EVIDENCE_MANIFEST\t(\{[^\n]+\})$/m, output,
        capture: :all_but_first
      )

    assert status == 0,
           "#{route} smoke session failed; retained evidence: #{runtime}; external fixture root: #{fixture_root}\nmanifest frames: #{inspect(frames)}\n#{output}"

    refute output =~ "TurnEndFailFast",
           "#{route} smoke fail-fast fired on a clean run; retained evidence: #{runtime}\n#{output}"

    assert [[frame]] = frames
    locator = Jason.decode!(frame)
    manifest = Path.join(root, locator["manifest_path"])
    assert File.regular?(manifest)
    assert sha256(manifest) == locator["sha256"]

    {integrity_output, integrity_status} =
      System.cmd(
        "python3",
        [
          "-B",
          Path.join(support, "integrity.py"),
          "--root",
          root,
          "--validate-manifest",
          manifest,
          "--smoke"
        ],
        stderr_to_stdout: true,
        env: [
          # IsolatedCase supplies offline Jev defaults; paid dispatch must use
          # the real Keychain and transport, never that replay vocabulary.
          {"KOGEN_JEV_TRANSPORT", nil},
          {"KOGEN_JEV_SECURITY", nil},
          {"KOGEN_SHAPING_EVALUATION_RUNTIME", runtime},
          {"KOGEN_SHAPING_EVALUATION_ELIXIR_CODE_PATHS", parser_code_paths()}
        ]
      )

    assert integrity_status == 0,
           "#{route} smoke manifest failed smoke-mode validation; retained evidence: #{runtime}\n#{integrity_output}"

    assert integrity_output =~ "manifest: valid"

    payload = Jason.decode!(File.read!(manifest))
    paths = Enum.map(payload["required_evidence"], & &1["path"])
    refute Enum.any?(paths, &String.contains?(&1, "/owned-rollouts/"))
    refute Enum.any?(paths, &String.contains?(&1, "/private-raw-rollouts/"))
    refute Enum.any?(paths, &(Path.basename(&1) in ["receipt.json", "transport.log", "pty.log"]))

    run = Path.join(runtime, "runs/smoke")
    record = read_json!(Path.join(run, "config-record.json"))
    status_final = read_json!(Path.join(run, "status-final.json"))
    result = read_json!(Path.join(run, "smoke-result.json"))
    review = read_json!(Path.join(run, "review-receipt.json"))

    assert record["harness"] == route and record["route"] == route
    assert result["failures"] == [], "#{route}: #{inspect(result["failures"])}"

    # One provider session across the fresh turn and the resumed turn.
    assert [provider] = record["provider_session_ids"]
    assert status_final["provider"]["session_id"] == provider
    assert result["provider_session_ids"] == [provider]

    # A real audit finding on an earlier revision, then a ready full report for
    # the presented revision.
    presented = status_final["presented"]
    assert status_final["state"] == "ready"
    assert presented["id"] =~ ~r/^p-[0-9]+-[0-9a-f]{12}$/
    reports = run |> Path.join("shaping-audits/*/report.json") |> Path.wildcard()

    assert Enum.any?(reports, fn path ->
             report = read_json!(path)
             report["revision"] != presented["revision"] and report["findings"] not in [nil, []]
           end),
           "#{route}: no earlier revision carried an audit finding"

    presented_report = read_json!(Path.join(run, "presented-report.json"))
    assert presented_report["revision"] == presented["revision"]
    assert presented_report["scope"] == "full" and presented_report["readiness"] == "ready"

    assert review["outcome"] == "completed" and review["failure"] == nil
    assert review["elapsed_seconds"] <= @route_seconds

    assert route_elapsed <= @route_seconds + 5 * 60,
           "#{route} took #{route_elapsed}s including setup; retained evidence: #{runtime}"

    assert review["cleanup"]["all_reaped"] == true

    # A clean exit removed the route's fixture: no leftover private tree remains.
    refute File.exists?(Path.join(runtime, "smoke"))

    Enum.map(payload["required_evidence"], fn entry ->
      assert sha256(Path.join(root, entry["path"])) == entry["sha256"]
      entry
    end) ++ [%{"path" => locator["manifest_path"], "sha256" => locator["sha256"]}]
  end

  defp cleanup_external_fixture_root(fixture_root, runtime, route) do
    case File.ls(fixture_root) do
      {:ok, []} ->
        case File.rmdir(fixture_root) do
          :ok ->
            :ok

          {:error, reason} ->
            retain_external_fixture_diagnostic(runtime, route, fixture_root, [], reason)
        end

      {:ok, entries} ->
        retain_external_fixture_diagnostic(
          runtime,
          route,
          fixture_root,
          entries,
          :fixture_retained
        )

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        retain_external_fixture_diagnostic(runtime, route, fixture_root, [], reason)
    end
  end

  defp retain_external_fixture_diagnostic(runtime, route, fixture_root, entries, reason) do
    diagnostic = %{
      "route" => route,
      "fixture_root" => fixture_root,
      "entries" => entries,
      "reason" => to_string(reason)
    }

    File.write(
      Path.join(runtime, "#{route}-external-fixture-retention.json"),
      Jason.encode!(diagnostic, pretty: true)
    )
  end

  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()

  defp sha256(path),
    do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  # The isolated child deliberately has an empty private MIX_BUILD_PATH. Its
  # parser subprocess is a fresh BEAM, so pass the current parent VM's exact
  # compiled dependency paths across that boundary instead of relying on a
  # warm checkout cache.
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
