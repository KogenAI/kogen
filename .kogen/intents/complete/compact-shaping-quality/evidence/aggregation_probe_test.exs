defmodule Kogen.CompactShapingAggregationProbe do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  @cases ~w(csv-flawed csv-complete booking-flawed booking-complete csv-continuation)
  @base ".kogen/intents/drafts/compact-shaping-quality/evidence/aggregation-output"

  if System.get_env("KOGEN_ISOLATED_CASE_CHILD") == "1" do
    test "five independent producers feed one isolated manifest" do
      root = File.cwd!()
      File.mkdir!(@base)
      seed = Path.join(@base, "seed.yaml")
      File.write!(seed, "id: frozen-test-seed\nquestions: [replacement]\n")
      parent = self()

      tasks = Enum.map(@cases, fn id ->
        Task.async(fn ->
          send(parent, {:ready, id, self()})
          receive do
            :release -> :ok
          after
            5_000 -> raise "barrier timeout"
          end
          parsed = YamlElixir.read_from_file!(seed)
          path = Path.join(@base, id <> ".json")
          File.write!(path, Jason.encode!(%{id: id, seed: parsed, synthetic: true}))
          %{path: path, sha256: digest(File.read!(path))}
        end)
      end)

      ready = Enum.map(@cases, fn _ ->
        receive do
          {:ready, id, pid} -> {id, pid}
        after
          5_000 -> raise "missing producer"
        end
      end)
      assert Enum.sort(Enum.map(ready, &elem(&1, 0))) == Enum.sort(@cases)
      ready |> Enum.reverse() |> Enum.each(fn {_, pid} -> send(pid, :release) end)
      entries = Enum.map(tasks, &Task.await(&1, 5_000))
      assert length(entries) == 5
      manifest = Path.join(@base, "manifest.json")
      File.write!(manifest, Jason.encode!(%{schema_version: 1, required_evidence: entries}))
      frame = Jason.encode!(%{manifest_path: manifest, sha256: digest(File.read!(manifest))})
      assert Enum.all?(entries, &File.regular?(Path.join(root, &1.path)))
      IO.write("progress without newline")
      IO.write("\nKOGEN_TARGET_EVIDENCE_MANIFEST\t" <> frame <> "\n")
      IO.write(String.duplicate("later progress ", 500))
    end
  else
    test "aggregate reaches actual consumer after isolated cleanup" do
      output = capture_io(fn ->
        assert :ok = Kogen.IsolatedCase.run!(__ENV__.file,
          :"test five independent producers feed one isolated manifest",
          target_evidence: :required)
      end)
      assert {:ok, snapshot} = Kogen.Build.TargetEvidence.capture(output, "live", "shaping-probe")
      assert length(snapshot["required_evidence"]) == 5
      assert :ok = Kogen.Build.TargetEvidence.verify(snapshot)
      File.write!(Path.join(@base, "consumer-receipt.json"), Jason.encode!(snapshot, pretty: true))
    end
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
