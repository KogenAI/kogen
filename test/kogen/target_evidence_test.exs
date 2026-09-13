defmodule Kogen.TargetEvidenceTest do
  use ExUnit.Case, async: true

  alias Kogen.Build.TargetEvidence

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
      Path.join(System.tmp_dir!(), "kogen-target-evidence-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
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
