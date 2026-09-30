Code.require_file("../support/fixture_validation.ex", __DIR__)
Code.require_file("../support/live_reviewer_rework_fixture.ex", __DIR__)

defmodule Kogen.FixtureValidationTest do
  @moduledoc """
  Scenario offline-fixture-validation: replayable negative controls for the
  generated-fixture failures observed in live runs. Every control is fast,
  non-live and provider-free: it validates a small generated fixture through
  `Kogen.FixtureValidation` (which reaches `Kogen.Intent.read/2`,
  `Kogen.Build.Contract.load/2` and YamlElixir), and the wrong control is the
  earlier bad rendering.
  """
  use ExUnit.Case, async: true

  # Subprocesses run from this checkout, never the shared VM's mutable cwd.
  @project_root Path.expand("../..", __DIR__)

  alias Kogen.Build.Verification
  alias Kogen.FixtureValidation
  alias Kogen.LiveReviewerReworkFixture

  @slug "live-reviewer-rework-probe"

  defp fixture! do
    dir =
      Path.join(
        System.tmp_dir!(),
        "kogen-fixture-validation-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    File.write!(Path.join(dir, "Makefile"), "check:\n\t@true\n")
    File.write!(Path.join(dir, "mix.exs"), "# fixture\n")
    LiveReviewerReworkFixture.write_package!(dir)
    dir
  end

  defp spec do
    %{
      "kind" => "live-reviewer-rework",
      "label" => @slug,
      "required" => ["Makefile", "mix.exs"],
      "approved" => ".kogen/intents/approved/#{@slug}",
      "makefile_targets" => ["check"]
    }
  end

  defp scenarios_path(dir),
    do: Path.join(dir, ".kogen/intents/approved/#{@slug}/scenarios.yaml")

  test "the generated reviewer-rework package validates and its digest tracks the exact bytes" do
    dir = fixture!()

    assert {:ok, record} = FixtureValidation.validate(dir, spec())
    assert record["digest"] =~ ~r/\A[0-9a-f]{64}\z/
    assert record["files"] >= 5
    assert {:ok, ^record} = FixtureValidation.validate(dir, spec())

    File.write!(Path.join(dir, "mix.exs"), "# fixture, one byte later\n")
    assert {:ok, changed} = FixtureValidation.validate(dir, spec())
    refute changed["digest"] == record["digest"]

    # Volatile controller state never changes the digest of consumed inputs.
    File.mkdir_p!(Path.join(dir, ".kogen/runtime"))
    File.write!(Path.join(dir, ".kogen/runtime/state.json"), "{}")
    assert {:ok, ^changed} = FixtureValidation.validate(dir, spec())
  end

  test "generated files that embed run-specific values can be left out of the digest" do
    dir = fixture!()
    spec = Map.put(spec(), "digest_exclude", ["run-context.json"])

    File.write!(Path.join(dir, "run-context.json"), ~s({"at":1}))
    assert {:ok, first} = FixtureValidation.validate(dir, spec)
    File.write!(Path.join(dir, "run-context.json"), ~s({"at":2}))
    assert {:ok, ^first} = FixtureValidation.validate(dir, spec)

    assert {:ok, counted} = FixtureValidation.validate(dir, Map.delete(spec, "digest_exclude"))
    refute counted["digest"] == first["digest"]
  end

  test "the earlier unescaped YAML rendering is rejected and the escaped one accepted" do
    dir = fixture!()
    good = File.read!(scenarios_path(dir))

    # The observed defect: a value containing `: ` written without quoting.
    quoted = ~s(paid_reason: "offline-sufficient: the fixture check)
    assert good =~ quoted
    broken = String.replace(good, quoted, "paid_reason: offline-sufficient: the fixture check")
    refute broken == good
    File.write!(scenarios_path(dir), broken)

    assert {:error, reasons} = FixtureValidation.validate(dir, spec())

    assert Enum.any?(
             reasons,
             &(&1 =~ "scenarios.yaml" or &1 =~ "Contract.load")
           ),
           inspect(reasons)

    File.write!(scenarios_path(dir), good)
    assert {:ok, _} = FixtureValidation.validate(dir, spec())
  end

  test "values with quotes, colons and newlines survive only when escaped" do
    value = "say \"hi\": it's #not a comment\nsecond line: still one value"
    dir = fixture!()

    for {rendering, expected} <- [
          {"paid_reason: " <> Jason.encode!(value), :ok},
          {"paid_reason: " <> value, :error}
        ] do
      document = "- id: x\n  proof:\n    #{rendering |> String.replace("\n", "\n    ")}\n"
      File.write!(Path.join(dir, "probe.yaml"), document)

      result =
        FixtureValidation.validate(dir, %{
          "kind" => "probe",
          "label" => "probe",
          "yaml" => ["probe.yaml"]
        })

      case expected do
        :ok ->
          assert {:ok, _} = result

          assert {:ok, [%{"proof" => %{"paid_reason" => ^value}}]} =
                   YamlElixir.read_from_string(document)

        :error ->
          # Either the parser rejects it or it does not round-trip the value.
          round_trips? =
            match?(
              {:ok, [%{"proof" => %{"paid_reason" => ^value}}]},
              YamlElixir.read_from_string(document)
            )

          refute match?({:ok, _}, result) and round_trips?
      end
    end
  end

  test "missing required files, a broken Approved package and a missing check target are all reported" do
    dir = fixture!()
    File.rm!(Path.join(dir, "mix.exs"))
    File.write!(Path.join(dir, "Makefile"), "other:\n\t@true\n")
    File.rm!(Path.join(dir, ".kogen/intents/approved/#{@slug}/risks.yaml"))

    assert {:error, reasons} = FixtureValidation.validate(dir, spec())
    assert Enum.any?(reasons, &(&1 =~ "mix.exs"))
    assert Enum.any?(reasons, &(&1 =~ "risks.yaml"))
    assert Enum.any?(reasons, &(&1 =~ "target check"))
  end

  test "input-receipt hashes and README links are checked against the fixture on disk" do
    dir = fixture!()
    File.mkdir_p!(Path.join(dir, "evidence"))
    File.write!(Path.join(dir, "evidence/facts.json"), ~s({"a":1}))
    File.write!(Path.join(dir, "README.md"), "See [facts](evidence/facts.json).\n")

    hash = :crypto.hash(:sha256, ~s({"a":1})) |> Base.encode16(case: :lower)

    File.write!(
      Path.join(dir, "evidence/complete-input-receipt.json"),
      Jason.encode!(%{"inputs" => [%{"path" => "evidence/facts.json", "sha256" => hash}]})
    )

    spec = %{
      "kind" => "shaping-evaluation",
      "label" => "x",
      "json" => ["evidence/facts.json"],
      "readme_links" => "README.md",
      "input_receipt" => "evidence/complete-input-receipt.json"
    }

    assert {:ok, _} = FixtureValidation.validate(dir, spec)

    File.write!(Path.join(dir, "evidence/facts.json"), ~s({"a":2}))
    File.write!(Path.join(dir, "README.md"), "See [gone](evidence/gone.md).\n")
    assert {:error, reasons} = FixtureValidation.validate(dir, spec)
    assert Enum.any?(reasons, &(&1 =~ "records evidence/facts.json"))
    assert Enum.any?(reasons, &(&1 =~ "missing file: evidence/gone.md"))
  end

  test "a Draft seed must carry its identity, provenance and frozen hashes" do
    dir = fixture!()
    draft = Path.join(dir, ".kogen/intents/drafts/seed")
    File.mkdir_p!(draft)

    File.write!(
      Path.join(draft, "intent.yaml"),
      Jason.encode!(%{
        "id" => "01990000-0000-7000-8000-00000000c501",
        "slug" => "seed",
        "shaped_against" => %{"branch" => "main", "head" => "abc"},
        "shaping" => %{"harness" => "codex", "model" => "m", "effort" => "low", "started" => "t"}
      })
    )

    File.write!(Path.join(draft, "scenarios.yaml"), "- id: a\n  given: b\n")
    seed = Path.join(dir, "seed-copy")
    File.mkdir_p!(seed)

    hashes =
      for name <- ~w(intent.yaml scenarios.yaml), into: %{} do
        {name,
         :crypto.hash(:sha256, File.read!(Path.join(draft, name))) |> Base.encode16(case: :lower)}
      end

    File.write!(Path.join(seed, "frozen-hashes.json"), Jason.encode!(hashes))

    spec = %{
      "kind" => "draft",
      "label" => "seed",
      "draft" => %{"slug" => "seed", "frozen" => seed}
    }

    assert {:ok, _} = FixtureValidation.validate(dir, spec)

    File.write!(Path.join(draft, "scenarios.yaml"), "- id: a\n  given: changed\n")
    assert {:error, reasons} = FixtureValidation.validate(dir, spec)
    assert Enum.any?(reasons, &(&1 =~ "differs from its frozen hash"))
  end

  test "a helper context listing that names bundled skills is not itself a fixture failure" do
    dir = fixture!()

    # The compatibility helper prints its context, which names the bundled
    # .system skills. Whether that inventory is trustworthy is the isolation
    # oracle's question; fixture validation must not read fixture output.
    listing =
      "Context: imagegen, openai-docs, plugin-creator, skill-creator, skill-installer (.system)\n"

    File.write!(Path.join(dir, "helper-output.txt"), listing)
    File.write!(Path.join(dir, "README.md"), listing)

    assert {:ok, record} =
             FixtureValidation.validate(dir, Map.put(spec(), "required", ["helper-output.txt"]))

    assert record["files"] > 0
  end

  test "validation demands provider denial when the caller is a provider-denied prepare" do
    assert FixtureValidation.require_denied!(fn "KOGEN_PROVIDERS_DENIED" -> "1" end) == :ok
    assert FixtureValidation.require_denied!(fn _ -> "true" end) == :ok

    for absent <- [nil, "", "0"] do
      assert_raise RuntimeError, ~r/KOGEN_PROVIDERS_DENIED=1/, fn ->
        FixtureValidation.require_denied!(fn _ -> absent end)
      end
    end

    assert {:ok, %{"providers_denied" => flag}} = FixtureValidation.validate(fixture!(), spec())
    assert flag == FixtureValidation.denied?()
  end

  test "a prepare that dispatches a provider while denied fails as offline, never provider" do
    shims =
      Path.join(
        System.tmp_dir!(),
        "kogen-fv-shims-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(shims)
    on_exit(fn -> File.rm_rf!(shims) end)

    for name <- ~w(claude codex) do
      path = Path.join(shims, name)

      File.write!(
        path,
        "#!/bin/sh\necho \"Kogen denied a provider launch during prepare: #{name} $*\" >&2\nexit 97\n"
      )

      File.chmod!(path, 0o755)
    end

    {output, status} =
      System.cmd("sh", ["-c", "claude --print hello"],
        stderr_to_stdout: true,
        env: [
          {"PATH", shims <> ":" <> System.get_env("PATH")},
          {"KOGEN_PROVIDERS_DENIED", "1"},
          {"ANTHROPIC_API_KEY", nil}
        ],
        cd: @project_root
      )

    assert status == 97
    assert output =~ "denied a provider launch"

    # The generic prepare contract: only an explicit environment frame is an
    # environment failure; a denied dispatch carries none, so the controller
    # classifies it `offline` (a Candidate/prepare defect) and it is never
    # billed or reported as a provider failure.
    assert Verification.prepare_result(output) == nil
    refute output =~ "KOGEN_PREPARE_RESULT"
    refute output =~ ~r/provider (error|failure|marker)/i
  end
end
