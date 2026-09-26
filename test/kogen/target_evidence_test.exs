defmodule Kogen.TargetEvidenceTest do
  use ExUnit.Case, async: true

  alias Kogen.Build.{TargetEvidence, Verification, VerificationPlan}

  test "a controller-run target that fails still returns a receipt carrying the evidence it emitted before failing" do
    root = git_fixture!()
    on_exit(fn -> File.rm_rf(root) end)

    {frame, _expected} = evidence!(root, [{"evidence.bin", <<9, 8, 7>>}])
    File.write!(Path.join(root, "frame.txt"), frame)

    File.write!(Path.join(root, "Makefile"), """
    .PHONY: evidence
    evidence:
    \t@cat frame.txt
    \t@exit 1
    """)

    File.mkdir_p!(Path.join(root, "priv/kogen"))

    File.write!(
      Path.join(root, "priv/kogen/verification_targets.yaml"),
      Jason.encode!(%{
        "targets" => [
          %{
            "name" => "evidence",
            "cost_class" => "offline",
            "rank" => 0,
            "dependencies" => [],
            "provider_backed" => false,
            "owner" => "fixture"
          }
        ]
      })
    )

    {:ok, catalog} = VerificationPlan.load(root)
    plan = %{targets: ["evidence"], added: [], scenarios: [], catalog_sha256: catalog.sha256}

    env = %{
      root: root,
      catalog: catalog,
      plan: plan,
      scenarios: [],
      base_commit: nil,
      candidate_id: fn -> {:ok, tree!(root)} end
    }

    tracking_path =
      Path.join([root, ".kogen/runtime/scenario-tracking/target-evidence-build", "tracking.json"])

    {:ok, execution} =
      Verification.initialize(tracking_path, "token-evidence", 0, plan.targets, 2, plan)

    candidate_id = tree!(root)

    {:ok, _execution, state} =
      Verification.run_cycle(execution, "session-evidence", candidate_id, env)

    cycle = List.last(state["cycles"])
    assert cycle["status"] == "failed"
    [receipt] = cycle["receipts"]
    assert receipt["status"] == "failed"
    assert receipt["target"] == "evidence"

    evidence = receipt["target_evidence"]
    assert evidence["target"] == "evidence"
    assert :ok = TargetEvidence.verify(evidence, root)
  end

  # The fixture's Candidate tree without changing this async test's cwd.
  defp tree!(root) do
    {_out, 0} = System.cmd("git", ["add", "-A"], cd: root)
    {tree, 0} = System.cmd("git", ["write-tree"], cd: root)
    String.trim(tree)
  end

  test "captures exact manifest and every required artifact independently of citations" do
    root = fixture!()
    on_exit(fn -> File.rm_rf(root) end)

    {frame, expected} = evidence!(root, [{"one.bin", <<0, 1, 2>>}, {"two.txt", "uncited\n"}])
    output = "progress without newline" <> frame <> "\n" <> String.duplicate("private-tail", 600)

    assert {:ok, snapshot} = TargetEvidence.capture(output, "bounded", "attempt-1", root)
    assert snapshot["target"] == "bounded"
    assert snapshot["attempt_token"] == "attempt-1"
    assert Base.decode64!(snapshot["manifest"]["content_base64"]) == expected.manifest

    assert Enum.map(snapshot["required_evidence"], fn retained ->
             {retained["path"], Base.decode64!(retained["content_base64"])}
           end) == expected.entries

    assert :ok = TargetEvidence.verify(snapshot, root)
  end

  test "rejects malformed, duplicate, unsafe, absent, nonregular and mismatched evidence" do
    root = fixture!()
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(Path.join(root, "directory"))
    File.write!(Path.join(root, "artifact"), "bytes")
    File.ln_s!(Path.join(root, "artifact"), Path.join(root, "linked"))

    cases = [
      {"malformed frame", "KOGEN_TARGET_EVIDENCE_MANIFEST\t{\n"},
      {"duplicate frame", valid_empty_frame(root) <> "\n" <> valid_empty_frame(root)},
      {"invalid schema",
       manifest_frame!(
         root,
         %{
           "schema_version" => 2,
           "required_evidence" => [entry("artifact", "bytes")]
         },
         "invalid-schema.json"
       )},
      {"duplicate path",
       manifest_frame!(
         root,
         %{
           "schema_version" => 1,
           "required_evidence" => [entry("artifact", "bytes"), entry("artifact", "bytes")]
         },
         "duplicate.json"
       )},
      {"parent path",
       manifest_frame!(
         root,
         %{
           "schema_version" => 1,
           "required_evidence" => [entry("../artifact", "bytes")]
         },
         "parent.json"
       )},
      {"missing",
       manifest_frame!(
         root,
         %{
           "schema_version" => 1,
           "required_evidence" => [entry("missing", "bytes")]
         },
         "missing.json"
       )},
      {"nonregular",
       manifest_frame!(
         root,
         %{
           "schema_version" => 1,
           "required_evidence" => [entry("directory", "bytes")]
         },
         "nonregular.json"
       )},
      {"symlink",
       manifest_frame!(
         root,
         %{
           "schema_version" => 1,
           "required_evidence" => [entry("linked", "bytes")]
         },
         "symlink.json"
       )},
      {"digest mismatch",
       manifest_frame!(
         root,
         %{
           "schema_version" => 1,
           "required_evidence" => [%{"path" => "artifact", "sha256" => sha("other")}]
         },
         "mismatch.json"
       )}
    ]

    for {label, frame} <- cases do
      assert {:error, reason} = TargetEvidence.capture(frame, "bounded", "attempt-1", root), label
      assert is_binary(reason) and reason != ""
    end
  end

  test "rejects source mutation, removal and decoded-byte forgery after capture" do
    root = fixture!()
    on_exit(fn -> File.rm_rf(root) end)
    {frame, _expected} = evidence!(root, [{"artifact", "original"}])
    assert {:ok, snapshot} = TargetEvidence.capture(frame, "bounded", "attempt-1", root)

    forged =
      put_in(
        snapshot,
        ["required_evidence", Access.at(0), "content_base64"],
        Base.encode64("forged")
      )

    assert {:error, _} = TargetEvidence.verify(forged, root)

    File.write!(Path.join(root, "artifact"), "changed")
    assert {:error, _} = TargetEvidence.verify(snapshot, root)

    File.rm!(Path.join(root, "artifact"))
    assert {:error, _} = TargetEvidence.verify(snapshot, root)
  end

  test "ordinary output without a frame remains optional" do
    assert {:ok, nil} = TargetEvidence.capture("ordinary target output", "ordinary", "attempt-1")
  end

  defp fixture! do
    root =
      Path.join(
        System.tmp_dir!(),
        "kogen-target-evidence-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    root
  end

  defp git_fixture! do
    root = fixture!()
    {_out, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: root, stderr_to_stdout: true)

    {_out, 0} =
      System.cmd("git", ["config", "user.email", "fixture@example.invalid"], cd: root)

    {_out, 0} = System.cmd("git", ["config", "user.name", "Fixture"], cd: root)
    root
  end

  defp evidence!(root, entries) do
    Enum.each(entries, fn {path, bytes} -> File.write!(Path.join(root, path), bytes) end)

    manifest = %{
      "schema_version" => 1,
      "required_evidence" => Enum.map(entries, fn {path, bytes} -> entry(path, bytes) end)
    }

    frame = manifest_frame!(root, manifest)
    manifest_bytes = File.read!(Path.join(root, "manifest.json"))
    {frame, %{manifest: manifest_bytes, entries: entries}}
  end

  defp valid_empty_frame(root) do
    manifest_frame!(root, %{"schema_version" => 1, "required_evidence" => []})
  end

  defp manifest_frame!(root, manifest, name \\ "manifest.json") do
    bytes = Jason.encode!(manifest)
    File.write!(Path.join(root, name), bytes)

    "KOGEN_TARGET_EVIDENCE_MANIFEST\t" <>
      Jason.encode!(%{"manifest_path" => name, "sha256" => sha(bytes)}) <> "\n"
  end

  defp entry(path, bytes), do: %{"path" => path, "sha256" => sha(bytes)}
  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
