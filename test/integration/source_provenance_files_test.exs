defmodule Kogen.Integration.SourceProvenanceFilesTest do
  use ExUnit.Case, async: true
  alias Kogen.{SourceProvenance, WorkingContext}

  test "successful source publication is private, hash bound and preserves immutable predecessors" do
    root = Kogen.tmp_path("source-receipt")
    on_exit(fn -> File.rm_rf!(root) end)
    text = "  Δ🙂\r\n/private path/診断.txt\n  "

    doc = %{
      "version" => 1,
      "request" => SourceProvenance.request(text, "-"),
      "rounds" => [],
      "corrections" => [],
      "contract_sha256" => "contract",
      "comparison" => "omitted: exact literal; Refine and new approval required"
    }

    SourceProvenance.publish(root, "example", doc)
    path = SourceProvenance.path(root, "example")
    original = File.read!(path)
    assert JSON.decode!(original)["request"]["text"] == text
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(Path.dirname(path)).mode, 0o777) == 0o700
    ref = SourceProvenance.binding(root, "example", "contract")
    assert ref["sha256"] == WorkingContext.hash(original)
    assert SourceProvenance.validate_bound!(ref) == :ok
    assert SourceProvenance.card(ref) =~ doc["comparison"]
    refute SourceProvenance.card(ref) =~ text
    updated = Map.put(doc, "comparison", "addressed: settled literal")
    SourceProvenance.publish(root, "example", updated)
    archive = Path.join(Path.dirname(path), WorkingContext.hash(original) <> ".json")
    assert File.read!(archive) == original

    assert_raise Kogen.Error, ~r/source provenance custody/, fn ->
      SourceProvenance.validate_bound!(ref)
    end

    current_bytes = File.read!(path)
    archive = Path.join(Path.dirname(path), WorkingContext.hash(current_bytes) <> ".json")
    File.write!(archive, "damaged predecessor")
    File.chmod!(archive, 0o600)

    assert_raise Kogen.Error, ~r/source provenance custody/, fn ->
      SourceProvenance.publish(root, "example", doc)
    end

    assert File.read!(path) == current_bytes
    assert File.read!(archive) == "damaged predecessor"

    current = SourceProvenance.binding(root, "example", "contract")
    local = Path.join(root, ".kogen/local")
    File.rename!(local, local <> "-moved")
    File.ln_s!(local <> "-moved", local)

    try do
      assert_raise Kogen.Error, ~r/unsafe/, fn -> SourceProvenance.validate_bound!(current) end
    after
      File.rm!(local)
      File.rename!(local <> "-moved", local)
    end

    File.chmod!(Path.dirname(path), 0o755)
    assert_raise Kogen.Error, ~r/unsafe/, fn -> SourceProvenance.validate_bound!(current) end
    File.chmod!(Path.dirname(path), 0o700)
    File.rm!(path)
    assert_raise Kogen.Error, ~r/missing/, fn -> SourceProvenance.validate_bound!(current) end
    assert SourceProvenance.binding(root, "legacy", "contract") == nil
    assert SourceProvenance.message(nil) == "Source provenance: unavailable (legacy)"
  end

  test "source comparison is copied completely at its UTF-8 byte boundary, never silently clipped" do
    root = Kogen.tmp_path("source-comparison")
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, ".kogen/intents/example/intent.md")
    File.mkdir_p!(Path.dirname(path))

    for size <- [8191, 8192] do
      report = "omitted: Δ🙂 " <> String.duplicate("x", size - byte_size("omitted: Δ🙂 "))
      File.write!(path, "# Example\n\n## Source comparison\n" <> report <> "\n\n## Tests\n")
      assert SourceProvenance.comparison(root, "example") == report
    end

    for body <- [
          "# Missing\n",
          "## Source comparison\n\n## Tests\n",
          "## Source comparison\n" <> String.duplicate("x", 8193)
        ] do
      File.write!(path, body)

      assert_raise Kogen.Error, ~r/Source comparison/, fn ->
        SourceProvenance.comparison(root, "example")
      end
    end
  end
end
