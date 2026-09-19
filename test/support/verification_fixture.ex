defmodule Kogen.VerificationFixture do
  @moduledoc false

  def install!(root) do
    selector = "test/kogen/focused_fixture_test.exs"
    File.mkdir_p!(Path.join(root, "test/kogen"))
    File.write!(Path.join(root, selector), "# focused disposable Build fixture\n")

    Path.wildcard(Path.join(root, ".kogen/intents/approved/*/scenarios.yaml"))
    |> Enum.each(&add_proofs!(&1, selector))

    targets =
      root
      |> Path.join("Makefile")
      |> Kogen.Check.declared_targets()
      |> MapSet.delete(".PHONY")
      |> MapSet.to_list()
      |> Enum.sort()

    entries = Enum.map(targets, &entry(&1, selector))
    path = Path.join(root, "priv/kogen/verification_targets.yaml")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(%{"targets" => entries}))
  end

  defp add_proofs!(path, selector) do
    scenarios = YamlElixir.read_from_file!(path)
    intent = Path.join(Path.dirname(path), "intent.yaml") |> YamlElixir.read_from_file!()
    affected = List.first(intent["may_change_guarded_paths"]) || "dummy.txt"

    updated =
      Enum.map(scenarios, fn scenario ->
        target = Enum.find(scenario["verified_by"], &(&1 != "check")) || "none"

        reason =
          if target == "none",
            do: "offline-sufficient: disposable fixture exercises the lifecycle consumer",
            else:
              "provider-required: #{target}; observation: disposable fixture target settlement; offline-limit: focused fixture cannot establish outer dispatch"

        scenario
        |> Map.put_new("proof", %{
          "offline" => [selector],
          "paid_target" => target,
          "paid_reason" => reason,
          "affected_paths" => [affected]
        })
        |> Map.put("verified_by", ["check"] ++ if(target == "none", do: [], else: [target]))
      end)

    File.write!(path, Jason.encode!(updated))
  end

  defp entry("check", _selector),
    do: %{
      "name" => "check",
      "cost_class" => "offline",
      "rank" => 0,
      "dependencies" => [],
      "provider_backed" => false,
      "owner" => "fixture"
    }

  defp entry(target, selector) do
    %{
      "name" => target,
      "cost_class" => "provider-fixture",
      "rank" => 100 + :erlang.phash2(target, 100_000),
      "dependencies" => ["check"],
      "provider_backed" => true,
      "owner" => "fixture",
      "rehearsal" => %{
        "id" => "rehearse-#{target}",
        "command" => "mix test --exclude live #{selector}",
        "shared_entrypoints" => ["fixture.prepare", "fixture.consume"],
        "correct_fixture" => selector,
        "wrong_fixture" => "#{selector}:wrong",
        "trace_assertions" => ["fixture-consumed"]
      }
    }
  end
end
