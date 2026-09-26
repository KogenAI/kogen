Code.require_file("../support/shaping_evaluation/draft_audit.ex", __DIR__)

defmodule Kogen.LiveShapingSmokeTest do
  @moduledoc """
  Public, provider-backed transport-smoke check. It is deliberately
  live-only: a single standalone session (never a CASES member, never
  graded) proves the transport mechanics -- session start, real
  task_complete-driven turn ends, scripted-answer delivery, clean exit with
  every owned process reaped and the fixture cleaned -- and emits its own
  smoke-mode evidence manifest locator.
  """
  use Kogen.IsolatedCase, async: true

  @moduletag :live
  @tag isolated_required_output_prefix: "KOGEN_TARGET_EVIDENCE_MANIFEST"
  @tag isolated_required_output_manifest: true
  # The smoke case's own session is bounded at SMOKE_MAX_SECONDS (300s); this
  # outer bound additionally permits bounded copy/preflight/cleanup overhead.
  @moduletag timeout: 600_000

  test "one real public smoke session starts, ends its turns on task_complete, delivers the scripted answer, and emits one manifest locator" do
    root = File.cwd!()
    support = Path.join(root, "test/support/shaping_evaluation")

    runtime =
      Path.join(
        root,
        ".kogen/runtime/shaping-smoke-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.dirname(runtime))
    File.mkdir!(runtime)

    {output, status} =
      System.cmd(
        "python3",
        ["-B", Path.join(support, "driver.py"), "--smoke"],
        cd: root,
        env: [
          {"KOGEN_SHAPING_EVALUATION_RUNTIME", runtime},
          {"KOGEN_SHAPING_EVALUATION_ELIXIR_CODE_PATHS", parser_code_paths()}
        ],
        stderr_to_stdout: true
      )

    frames =
      Regex.scan(~r/^KOGEN_TARGET_EVIDENCE_MANIFEST\t(\{[^\n]+\})$/m, output,
        capture: :all_but_first
      )

    # Carry the manifest frame into the failure message, as the evaluation
    # owner does, so a failing smoke run's evidence locator is inspectable
    # directly from the ExUnit failure output.
    assert status == 0,
           "smoke session failed; retained evidence: #{runtime}\nmanifest frames: #{inspect(frames)}\n#{output}"

    # Fail-fast (driver.turn_end_decision) must never have fired on a clean run.
    refute output =~ "TurnEndFailFast",
           "smoke fail-fast fired on a clean run; retained evidence: #{runtime}\n#{output}"

    assert [frame] = frames
    locator = Jason.decode!(List.first(frame))
    manifest = Path.join(root, locator["manifest_path"])

    assert File.regular?(manifest)

    assert :crypto.hash(:sha256, File.read!(manifest)) |> Base.encode16(case: :lower) ==
             locator["sha256"]

    payload = Jason.decode!(File.read!(manifest))
    assert payload["schema_version"] == 1
    assert is_list(payload["required_evidence"]) and payload["required_evidence"] != []

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
          {"KOGEN_SHAPING_EVALUATION_RUNTIME", runtime},
          {"KOGEN_SHAPING_EVALUATION_ELIXIR_CODE_PATHS", parser_code_paths()}
        ]
      )

    assert integrity_status == 0,
           "smoke manifest failed smoke-mode validation; retained evidence: #{runtime}\n#{integrity_output}"

    assert integrity_output =~ "manifest: valid"

    # Build extracts this one validated record from the target's complete
    # output. Private native streams and transport logs stay outside the
    # concise manifest while the compact native receipt remains reviewable.
    IO.write("\nKOGEN_TARGET_EVIDENCE_MANIFEST\t" <> Jason.encode!(locator) <> "\n")

    paths = Enum.map(payload["required_evidence"], & &1["path"])
    refute Enum.any?(paths, &String.contains?(&1, "/owned-rollouts/"))
    refute Enum.any?(paths, &String.contains?(&1, "/private-raw-rollouts/"))
    refute Enum.any?(paths, &(Path.basename(&1) in ["receipt.json", "transport.log", "pty.log"]))

    Enum.each(payload["required_evidence"], fn entry ->
      assert File.regular?(Path.join(root, entry["path"]))

      assert :crypto.hash(:sha256, File.read!(Path.join(root, entry["path"])))
             |> Base.encode16(case: :lower) == entry["sha256"]
    end)

    # Exactly one scripted answer was sent and bound to a real terminal turn.
    review_receipt =
      payload["required_evidence"]
      |> Enum.find(&String.ends_with?(&1["path"], "runs/smoke/review-receipt.json"))
      |> Map.fetch!("path")
      |> then(&Path.join(root, &1))
      |> File.read!()
      |> Jason.decode!()

    assert review_receipt["case"] == "smoke"
    assert review_receipt["scripted_replies"] == 1
    assert review_receipt["outcome"] == "completed"
    assert review_receipt["failure"] == nil
    assert length(review_receipt["terminal_turn_bindings"]) == 1
    assert review_receipt["elapsed_seconds"] <= 300
    assert review_receipt["cleanup"]["all_reaped"] == true

    # A clean exit removed the fixture: no leftover private tree remains.
    refute File.exists?(Path.join(runtime, "smoke"))
  end

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
