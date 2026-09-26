Code.require_file("../support/verification_cycle_fixture.ex", __DIR__)

defmodule Kogen.CatalogChangeTest do
  @moduledoc """
  `Kogen.Build.CatalogChange.check/4` reads the Candidate's verification
  target catalog and Makefile only as data each cycle (scenario
  `same-intent-catalog-change`): a target declared in the admitted Intent's
  `catalog_changes.add` may be selected though absent at admission and takes
  its catalog entry from the Candidate once it exists there; every other
  selected target keeps its admission entry; a missing selected target fails
  the cycle (never the Build); an unselected target may be freely removed or
  edited. `Kogen.Build.VerificationPlan.build/5` separately rejects, at
  admission, a `verified_by` naming an unknown target and a `catalog_changes.add`
  naming a target that already exists.
  """

  use Kogen.IsolatedCase, async: true

  alias Kogen.Build.{CatalogChange, VerificationPlan}
  alias Kogen.VerificationCycleFixture, as: Fixture

  setup do
    root = Fixture.new!()
    on_exit(fn -> File.rm_rf(root) end)
    admission = Fixture.catalog!(root)
    {:ok, root: root, admission: admission}
  end

  describe "Kogen.Build.CatalogChange.check/4" do
    test "a declared added target the Developer adds to the catalog and Makefile then runs, keeping every admission entry unchanged",
         %{root: root, admission: admission} do
      x = added_entry("x", 300)

      # Superficially mutate the Candidate's admitted `check` entry: the
      # admission entry must still be the one the controller uses.
      Fixture.write_catalog_and_makefile!(root, [
        Map.put(Fixture.offline_entry("check"), "cost_class", "mutated"),
        Fixture.provider_entry("a", 100),
        Fixture.provider_entry("b", 200),
        x
      ])

      write_selector!(root)

      plan = %{targets: ["check", "x"], added: ["x"]}
      scenarios = [scenario("sc-x", ["check", "x"], "x")]

      assert {:ok, %{order: order, entries: entries, provider_backed: provider_backed}} =
               CatalogChange.check(root, admission, plan, scenarios)

      assert order == ["check", "x"]
      assert provider_backed == %{"check" => false, "x" => true}
      assert entries["check"] == admission.targets["check"]
      assert entries["check"]["cost_class"] == "offline"
      assert entries["x"] == Map.put(x, "depends_on", x["dependencies"])
    end

    test "a scenario selecting an added provider-backed target must list its rehearsal test as a file selector",
         %{root: root, admission: admission} do
      x = added_entry("x", 300)

      Fixture.write_catalog_and_makefile!(root, [
        Fixture.offline_entry("check"),
        Fixture.provider_entry("a", 100),
        Fixture.provider_entry("b", 200),
        x
      ])

      plan = %{targets: ["check", "x"], added: ["x"]}
      # No file selector at all: the added target's rehearsal test is never listed.
      scenarios = [
        %{
          "id" => "sc-x",
          "verified_by" => ["check", "x"],
          "proof" => %{"paid_target" => "x", "offline" => []}
        }
      ]

      assert {:error, reason} = CatalogChange.check(root, admission, plan, scenarios)
      assert reason =~ "without listing its rehearsal test as a file selector"
    end

    test "a selected target missing from the Candidate's catalog or Makefile fails the cycle, and restoring it succeeds",
         %{root: root, admission: admission} do
      plan = %{targets: ["check", "b"], added: []}
      scenarios = [scenario("sc-b", ["check", "b"], "b")]

      Fixture.write_catalog_and_makefile!(root, [Fixture.offline_entry("check")])

      assert {:error, reason} = CatalogChange.check(root, admission, plan, scenarios)
      assert reason =~ "missing from the Candidate catalog or Makefile"

      Fixture.write_catalog_and_makefile!(root, [
        Fixture.offline_entry("check"),
        Fixture.provider_entry("b", 200)
      ])

      assert {:ok, %{order: ["check", "b"]}} =
               CatalogChange.check(root, admission, plan, scenarios)
    end

    test "an unselected target may be removed or edited without failing the cycle", %{
      root: root,
      admission: admission
    } do
      plan = %{targets: ["check", "a"], added: []}
      scenarios = [scenario("sc-a", ["check", "a"], "a")]

      # `b` is not selected; drop it from both the catalog and the Makefile.
      Fixture.write_catalog_and_makefile!(root, [
        Fixture.offline_entry("check"),
        Fixture.provider_entry("a", 100)
      ])

      assert {:ok, %{order: ["check", "a"]}} =
               CatalogChange.check(root, admission, plan, scenarios)
    end

    test "an invalid added target entry (provider-backed without a rehearsal) fails the cycle",
         %{root: root, admission: admission} do
      invalid = Fixture.invalid_provider_entry("x", 300)

      Fixture.write_catalog_and_makefile!(root, [
        Fixture.offline_entry("check"),
        Fixture.provider_entry("a", 100),
        Fixture.provider_entry("b", 200),
        invalid
      ])

      plan = %{targets: ["check", "x"], added: ["x"]}
      scenarios = [scenario("sc-x", ["check", "x"], "x")]

      assert {:error, reason} = CatalogChange.check(root, admission, plan, scenarios)
      assert reason =~ "Candidate verification target catalog is invalid"
    end
  end

  describe "Kogen.Build.VerificationPlan.build/5 admission rules" do
    test "a verified_by naming an unknown target is rejected at admission", %{
      root: root,
      admission: admission
    } do
      write_selector!(root)

      scenario = %{
        "verified_by" => ["check", "ghost"],
        "proof" => %{
          "offline" => ["test/kogen/dummy_test.exs"],
          "paid_target" => "none",
          "paid_reason" => "offline-sufficient: an unknown target must never be admitted",
          "affected_paths" => ["test/kogen/dummy_test.exs"]
        }
      }

      assert {:error, "scenario proof map is missing, unsafe, or inconsistent"} =
               VerificationPlan.build([scenario], ["test/**"], admission, root)
    end

    test "catalog_changes.add naming an already-existing target is rejected at admission", %{
      root: root,
      admission: admission
    } do
      write_selector!(root)

      scenario = %{
        "verified_by" => ["check"],
        "proof" => %{
          "offline" => ["test/kogen/dummy_test.exs"],
          "paid_target" => "none",
          "paid_reason" => "offline-sufficient: check alone is enough",
          "affected_paths" => ["test/kogen/dummy_test.exs"]
        }
      }

      assert {:error, reason} =
               VerificationPlan.build([scenario], ["test/**"], admission, root, added: ["check"])

      assert reason =~ "catalog_changes.add names a target that already exists: check"
    end
  end

  describe "full Kogen.Build.run fake-harness Builds" do
    test "a declared added target that is selected and run reaches Review in one attempt" do
      dir = Fixture.harness_project!(declared_add: true, paid_at_admission: false)
      on_exit(fn -> File.rm_rf(dir) end)

      # Nothing runnable yet: `paid` is declared in catalog_changes.add but
      # absent from the admission catalog and Makefile. The Developer's
      # first turn adds it to both.
      assert :ok =
               Fixture.run_full_harness(dir,
                 edits: %{1 => Fixture.harness_add_paid_command()}
               )

      record = Fixture.harness_record!(dir)
      assert [attempt] = record["attempts"]
      assert attempt["outcome"] == "settled"
      assert Enum.map(attempt["verification"]["cycles"], & &1["status"]) == ["passed"]

      assert Enum.map(hd(attempt["verification"]["cycles"])["receipts"], & &1["target"]) ==
               ["check", "paid"]

      assert Fixture.harness_resume_prompts(dir) == []
      assert length(Path.wildcard(Path.join(dir, ".kogen/runtime/developer-prompt-*"))) == 1
    end

    test "a selected target removed from the Candidate resumes the same Developer session and does not stop the Build" do
      dir = Fixture.harness_project!(paid_at_admission: true)
      on_exit(fn -> File.rm_rf(dir) end)

      assert :ok =
               Fixture.run_full_harness(dir,
                 edits: %{1 => Fixture.harness_remove_paid_command()},
                 resume_edits: %{1 => Fixture.harness_add_paid_command()}
               )

      record = Fixture.harness_record!(dir)
      assert [attempt] = record["attempts"]
      assert attempt["outcome"] == "settled"

      cycles = attempt["verification"]["cycles"]
      assert Enum.map(cycles, & &1["status"]) == ["failed", "passed"]
      assert Enum.uniq(Enum.map(cycles, & &1["developer_session_id"])) |> length() == 1
      assert hd(cycles)["failure"]["kind"] == "catalog"

      resumes = Fixture.harness_resume_prompts(dir)
      assert length(resumes) == 1
      assert hd(resumes) =~ "Controller verification failed after your turn"
      assert hd(resumes) =~ "paid"

      assert length(Path.wildcard(Path.join(dir, ".kogen/runtime/developer-prompt-*"))) == 1
    end
  end

  defp added_entry(name, rank) do
    Fixture.provider_entry(name, rank)
    |> Map.put("rehearsal", %{
      "id" => "rehearse-#{name}",
      "command" => "mix test test/kogen/dummy_test.exs",
      "shared_entrypoints" => ["#{name}.entrypoint"],
      "correct_fixture" => "#{name}-correct",
      "wrong_fixture" => "#{name}-wrong",
      "trace_assertions" => ["#{name}-trace"]
    })
  end

  defp scenario(id, verified_by, target) do
    %{
      "id" => id,
      "verified_by" => verified_by,
      "proof" => %{
        "paid_target" => target,
        "offline" => ["test/kogen/dummy_test.exs"]
      }
    }
  end

  defp write_selector!(root) do
    path = Path.join(root, "test/kogen/dummy_test.exs")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "# selector fixture\n")
  end
end
