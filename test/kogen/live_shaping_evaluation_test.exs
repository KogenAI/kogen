Code.require_file("../support/shaping_evaluation/draft_audit.ex", __DIR__)

defmodule Kogen.LiveShapingEvaluationTest do
  @moduledoc """
  Public, provider-backed five-session Shaping regression. It is deliberately
  live-only: each case runs once, retains original evidence under the parent
  checkout's ignored runtime tree, and emits the optional target-evidence
  locator for Build/Reviewer delivery.
  """
  use Kogen.IsolatedCase, async: true

  @moduletag :live
  @tag isolated_required_output_prefix: "KOGEN_TARGET_EVIDENCE_MANIFEST"
  @tag isolated_required_output_manifest: true
  # Five sessions have independent ten-minute caps. This outer bound also
  # permits bounded copy/preflight/cleanup overhead and never changes a
  # session's own envelope; `System.cmd/3` itself has no timeout option.
  @moduletag timeout: 5_700_000

  test "five real public shaping sessions retain evidence and emit one manifest locator" do
    root = File.cwd!()
    support = Path.join(root, "test/support/shaping_evaluation")

    runtime =
      Path.join(
        root,
        ".kogen/runtime/shaping-evaluation-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.dirname(runtime))
    File.mkdir!(runtime)

    {output, status} =
      System.cmd(
        "python3",
        ["-B", Path.join(support, "driver.py"), "suite"],
        cd: root,
        env: [
          {"KOGEN_SHAPING_EVALUATION_RUNTIME", runtime},
          {"KOGEN_SHAPING_EVALUATION_ELIXIR_CODE_PATHS", parser_code_paths()}
        ],
        stderr_to_stdout: true
      )

    assert status == 0,
           "five-session shaping evaluation failed; retained evidence: #{runtime}\n#{output}"

    frames =
      Regex.scan(~r/^KOGEN_TARGET_EVIDENCE_MANIFEST\t(\{[^\n]+\})$/m, output,
        capture: :all_but_first
      )

    assert [frame] = frames
    locator = Jason.decode!(List.first(frame))
    manifest = Path.join(root, locator["manifest_path"])

    assert File.regular?(manifest)

    assert :crypto.hash(:sha256, File.read!(manifest)) |> Base.encode16(case: :lower) ==
             locator["sha256"]

    payload = Jason.decode!(File.read!(manifest))
    assert payload["schema_version"] == 1
    assert is_list(payload["required_evidence"]) and payload["required_evidence"] != []

    {integrity_output, 0} =
      System.cmd(
        "python3",
        [
          "-B",
          Path.join(support, "integrity.py"),
          "--root",
          root,
          "--validate-manifest",
          manifest
        ],
        stderr_to_stdout: true,
        env: [
          {"KOGEN_SHAPING_EVALUATION_RUNTIME", runtime},
          {"KOGEN_SHAPING_EVALUATION_ELIXIR_CODE_PATHS", parser_code_paths()}
        ]
      )

    assert integrity_output =~ "manifest: valid"
    assert :ok = Kogen.ShapingDraftAudit.audit!(Path.dirname(manifest))

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
