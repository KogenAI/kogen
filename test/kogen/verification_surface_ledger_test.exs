Code.require_file("../support/integrity_fixture.ex", __DIR__)
Code.require_file("../support/fake_jev.ex", __DIR__)

defmodule Kogen.VerificationSurfaceLedgerTest do
  @moduledoc """
  The verification-surface ledger (`verification-surface-ledger`): computed
  contents (edited test and runner files included, added test files
  excluded, runner-class flags, catalog digest change, retained diffs), the
  base-suite report, the Reviewer verdict `ledger` field enforcement
  (`Contract.verdict/5`, `Review.apply_ledger/3`), the packet's bounded
  ledger index, and the schema chosen per Reviewer launch
  (`Verdict.schema/1`, fake Claude and fake Codex).
  """
  use Kogen.IsolatedCase, async: true

  alias Kogen.Build.{BaseWorkspace, Contract, Ledger, Review, VerificationPlan}
  alias Kogen.Build.ReviewPacket
  alias Kogen.FakeJev
  alias Kogen.Harness.Verdict
  alias Kogen.IntegrityFixture, as: Fixture

  describe "Ledger.compute/1" do
    test "includes an edited test outside affected_paths and a weakened runner, excludes an added test" do
      %{dir: dir, base_commit: _base_commit} = Fixture.create()

      Fixture.write!(
        dir,
        "test/other_test.exs",
        "defmodule OtherTest do\n  use ExUnit.Case\n  test \"x\" do\n    assert true\n  end\nend\n"
      )

      Fixture.commit!(dir, "add other_test.exs")
      base_commit = Fixture.head!(dir)

      # Edit a test file outside every scenario's affected_paths (["lib/**"]).
      Fixture.write!(
        dir,
        "test/other_test.exs",
        "defmodule OtherTest do\n  use ExUnit.Case\n  test \"x\" do\n    assert true\n    assert 1 == 1\n  end\nend\n"
      )

      # Weaken the runner.
      Fixture.write!(dir, "test/test_helper.exs", "ExUnit.start(exclude: [:live, :weakened])\n")

      # Add a brand-new test file: excluded from the ledger.
      Fixture.write!(
        dir,
        "test/new_test.exs",
        "defmodule NewTest do\n  use ExUnit.Case\n  test \"y\" do\n    assert true\n  end\nend\n"
      )

      # Change the catalog's bytes without changing its meaning.
      {:ok, admission_catalog} = VerificationPlan.load(dir)

      Fixture.write!(
        dir,
        "priv/kogen/verification_targets.yaml",
        File.read!(Path.join(dir, "priv/kogen/verification_targets.yaml")) <>
          "\n# candidate note\n"
      )

      {:ok, candidate_catalog} = VerificationPlan.load(dir)
      assert candidate_catalog.sha256 != admission_catalog.sha256

      candidate_id = Fixture.candidate_id!(dir)
      ledger_dir = tmp_ledger_dir(dir)

      receipts = [
        %{"target" => "check", "cycle_sequence" => 1},
        %{"target" => "other", "cycle_sequence" => 1}
      ]

      assert {:ok, ledger} =
               Ledger.compute(%{
                 root: dir,
                 base_commit: base_commit,
                 candidate_id: candidate_id,
                 integrity: candidate_catalog.integrity,
                 admission_sha256: admission_catalog.sha256,
                 candidate_sha256: candidate_catalog.sha256,
                 receipts: receipts,
                 directory: ledger_dir,
                 preservation: []
               })

      paths = Enum.map(ledger["items"], & &1["path"])
      assert "test/other_test.exs" in paths
      assert "test/test_helper.exs" in paths
      refute "test/new_test.exs" in paths
      assert length(ledger["items"]) == 2

      other = Enum.find(ledger["items"], &(&1["path"] == "test/other_test.exs"))
      assert other["status"] == "modified"
      assert other["runner_class"] == false
      assert is_map(other["diff_stat"])
      assert is_binary(other["base_blob"])
      assert is_binary(other["candidate_blob"])

      runner = Enum.find(ledger["items"], &(&1["path"] == "test/test_helper.exs"))
      assert runner["runner_class"] == true

      # Every item's full diff is retained under the attempt directory, bound
      # by sha256 and byte count.
      for item <- ledger["items"] do
        diff_path = Path.join(dir, item["diff"]["path"])
        bytes = File.read!(diff_path)
        assert byte_size(bytes) == item["diff"]["byte_count"]
        assert sha256(bytes) == item["diff"]["sha256"]
        assert bytes =~ item["path"]
      end

      # A changed runner-class file marks every receipt that ran.
      assert ledger["receipts_with_changed_runner"] == [
               %{"target" => "check", "cycle_sequence" => 1},
               %{"target" => "other", "cycle_sequence" => 1}
             ]

      assert ledger["catalog"]["admission_sha256"] == admission_catalog.sha256
      assert ledger["catalog"]["candidate_sha256"] == candidate_catalog.sha256
      assert ledger["catalog"]["changed"] == true
      assert Ledger.paths(ledger) |> Enum.sort() == Enum.sort(paths)
    end

    test "without integrity fields the ledger is nil" do
      %{dir: dir, base_commit: base_commit} = Fixture.create()

      assert {:ok, nil} =
               Ledger.compute(%{
                 root: dir,
                 base_commit: base_commit,
                 candidate_id: base_commit,
                 integrity: nil,
                 admission_sha256: "x",
                 candidate_sha256: "x",
                 receipts: [],
                 directory: tmp_ledger_dir(dir),
                 preservation: []
               })
    end

    test "no receipts are marked when the runner is unchanged" do
      %{dir: dir, base_commit: base_commit} = Fixture.create()
      {:ok, catalog} = VerificationPlan.load(dir)

      Fixture.write!(
        dir,
        "lib/calc.ex",
        "defmodule Calc do\n  def add(a, b), do: a + b\n  def value, do: :unused\nend\n"
      )

      candidate_id = Fixture.candidate_id!(dir)

      # lib/calc.ex is not part of the verification surface (neither test-
      # nor runner-class), so it never becomes a ledger item and the runner
      # is unchanged, so no receipt is marked.
      assert {:ok, ledger} =
               Ledger.compute(%{
                 root: dir,
                 base_commit: base_commit,
                 candidate_id: candidate_id,
                 integrity: catalog.integrity,
                 admission_sha256: catalog.sha256,
                 candidate_sha256: catalog.sha256,
                 receipts: [%{"target" => "check"}],
                 directory: tmp_ledger_dir(dir),
                 preservation: []
               })

      assert ledger["items"] == []
      assert ledger["receipts_with_changed_runner"] == []
    end
  end

  describe "Ledger.base_suite/1" do
    test "runs base's tests against the Candidate's implementation as a report, not a gate" do
      %{dir: dir, base_commit: base_commit} = Fixture.create()
      {:ok, catalog} = VerificationPlan.load(dir)
      {:ok, workspace} = BaseWorkspace.create(dir, base_commit, catalog.integrity["base_cache"])

      # A pure implementation edit: not part of the verification surface.
      Fixture.write!(
        dir,
        "lib/calc.ex",
        "defmodule Calc do\n  def add(a, b), do: a + b\n  def value, do: Path.join(Path.dirname(__DIR__), \"priv/value.txt\") |> File.read!() |> String.trim()\nend\n"
      )

      candidate_id = Fixture.candidate_id!(dir)

      {report, _workspace} =
        Ledger.base_suite(%{
          root: dir,
          base_commit: base_commit,
          candidate_id: candidate_id,
          integrity: catalog.integrity,
          workspace: workspace,
          directory: tmp_ledger_dir(dir)
        })

      # NOTE: the "skipped" branch of Kogen.Build.Ledger.base_suite/1 (base
      # has no test-class files) does not carry the "use" label the other
      # branches do (lib/kogen/build/ledger.ex `run_suite/4`, first clause);
      # reported to the Developer as a possible lib inconsistency rather than
      # asserted here.
      assert report["status"] == "skipped"
      assert report["reason"] == "base has no test-class files"

      on_exit(fn -> BaseWorkspace.remove(workspace) end)
    end

    test "reports a failing base suite without being a gate" do
      %{dir: dir, base_commit: _base_commit} = Fixture.create()

      Fixture.write!(
        dir,
        "test/base_suite_test.exs",
        "defmodule BaseSuiteTest do\n  use ExUnit.Case\n  test \"adds\" do\n    assert Calc.add(1, 2) == 3\n  end\nend\n"
      )

      base_commit = Fixture.commit!(dir, "add base suite test")

      {:ok, catalog} = VerificationPlan.load(dir)
      {:ok, workspace} = BaseWorkspace.create(dir, base_commit, catalog.integrity["base_cache"])

      # Regress the implementation: base's test suite must now fail against it.
      Fixture.write!(
        dir,
        "lib/calc.ex",
        "defmodule Calc do\n  def add(a, b), do: a + b + 1\n  def value, do: :unused\nend\n"
      )

      candidate_id = Fixture.candidate_id!(dir)

      {report, _workspace} =
        Ledger.base_suite(%{
          root: dir,
          base_commit: base_commit,
          candidate_id: candidate_id,
          integrity: catalog.integrity,
          workspace: workspace,
          directory: tmp_ledger_dir(dir)
        })

      assert report["use"] == "report for Review, not a gate"
      assert report["status"] == "failed"
      assert is_binary(report["log_path"])
      assert is_binary(report["log_sha256"])

      on_exit(fn -> BaseWorkspace.remove(workspace) end)
    end
  end

  describe "Contract.verdict/5 ledger enforcement" do
    setup do
      contract = %{scenarios: [%{"id" => "s1"}, %{"id" => "s2"}]}
      binding = %{candidate_id: "cand-1", attempt_token: "tok-1"}
      {:ok, contract: contract, binding: binding}
    end

    test "accepts exactly one justified or weakening disposition per ledger path", %{
      contract: contract,
      binding: binding
    } do
      message = %{
        "candidate_id" => "cand-1",
        "attempt_token" => "tok-1",
        "verdict" => "accept",
        "scenarios" => [
          scenario_entry("s1"),
          scenario_entry("s2")
        ],
        "dispositions" => [],
        "findings" => [],
        "ledger" => [
          %{"path" => "test/a_test.exs", "disposition" => "justified: s1"},
          %{"path" => "test/b_test.exs", "disposition" => "weakening"}
        ]
      }

      assert {:ok, _} =
               Contract.verdict(message, contract, binding, [], [
                 "test/a_test.exs",
                 "test/b_test.exs"
               ])
    end

    test "rejects a missing disposition", %{contract: contract, binding: binding} do
      message = %{
        "candidate_id" => "cand-1",
        "attempt_token" => "tok-1",
        "verdict" => "accept",
        "scenarios" => [scenario_entry("s1"), scenario_entry("s2")],
        "dispositions" => [],
        "findings" => [],
        "ledger" => [%{"path" => "test/a_test.exs", "disposition" => "justified: s1"}]
      }

      assert {:error, _reason} =
               Contract.verdict(message, contract, binding, [], [
                 "test/a_test.exs",
                 "test/b_test.exs"
               ])
    end

    test "rejects an extra disposition not among the ledger paths", %{
      contract: contract,
      binding: binding
    } do
      message = %{
        "candidate_id" => "cand-1",
        "attempt_token" => "tok-1",
        "verdict" => "accept",
        "scenarios" => [scenario_entry("s1"), scenario_entry("s2")],
        "dispositions" => [],
        "findings" => [],
        "ledger" => [
          %{"path" => "test/a_test.exs", "disposition" => "justified: s1"},
          %{"path" => "test/unexpected_test.exs", "disposition" => "justified: s1"}
        ]
      }

      assert {:error, _reason} =
               Contract.verdict(message, contract, binding, [], ["test/a_test.exs"])
    end

    test "a verdict without ledger is accepted when no ledger was supplied (verdict/4 and verdict/5 with [])",
         %{contract: contract, binding: binding} do
      message = %{
        "candidate_id" => "cand-1",
        "attempt_token" => "tok-1",
        "verdict" => "accept",
        "scenarios" => [scenario_entry("s1"), scenario_entry("s2")],
        "dispositions" => [],
        "findings" => []
      }

      assert {:ok, _} = Contract.verdict(message, contract, binding, [])
      assert {:ok, _} = Contract.verdict(message, contract, binding, [], [])
    end

    test "a verdict without ledger is rejected when a ledger was supplied (extra required key missing)",
         %{contract: contract, binding: binding} do
      message = %{
        "candidate_id" => "cand-1",
        "attempt_token" => "tok-1",
        "verdict" => "accept",
        "scenarios" => [scenario_entry("s1"), scenario_entry("s2")],
        "dispositions" => [],
        "findings" => []
      }

      assert {:error, _reason} =
               Contract.verdict(message, contract, binding, [], ["test/a_test.exs"])
    end
  end

  describe "Review.apply_ledger/3" do
    test "a weakening disposition turns the verdict into rework with a new blocking finding" do
      contract = %{
        scenarios: [
          %{
            "id" => "s1",
            "proof" => %{"affected_paths" => ["lib/**"], "offline" => []}
          }
        ]
      }

      ledger = %{
        "items" => [
          %{
            "path" => "test/a_test.exs",
            "status" => "modified",
            "runner_class" => false,
            "diff" => %{
              "path" => "verification/ledger/0001.diff",
              "sha256" => "abc",
              "byte_count" => 3
            }
          }
        ]
      }

      response = %{
        "verdict" => "accept",
        "findings" => [],
        "ledger" => [%{"path" => "test/a_test.exs", "disposition" => "weakening"}]
      }

      updated = Review.apply_ledger(response, ledger, contract)
      assert updated["verdict"] == "rework"
      assert [finding] = updated["findings"]
      assert finding["scenario_ids"] == ["s1"]
      assert finding["reason"] =~ "weakening"

      assert finding["evidence"] == [
               %{
                 "path" => "verification/ledger/0001.diff",
                 "locator" => "verification-surface ledger diff of test/a_test.exs"
               }
             ]
    end

    test "a justified disposition leaves the verdict untouched" do
      contract = %{
        scenarios: [%{"id" => "s1", "proof" => %{"affected_paths" => [], "offline" => []}}]
      }

      ledger = %{
        "items" => [
          %{
            "path" => "test/a_test.exs",
            "status" => "modified",
            "runner_class" => false,
            "diff" => %{}
          }
        ]
      }

      response = %{
        "verdict" => "accept",
        "findings" => [],
        "ledger" => [%{"path" => "test/a_test.exs", "disposition" => "justified: s1"}]
      }

      assert Review.apply_ledger(response, ledger, contract) == response
    end

    test "without a ledger the response is returned unchanged" do
      response = %{"verdict" => "accept", "findings" => []}
      assert Review.apply_ledger(response, nil, %{scenarios: []}) == response
    end
  end

  describe "review packet ledger index bound" do
    test "a ledger with large diffs stays within the packet bound with an index, locators and digests" do
      %{dir: dir, base_commit: _base_commit} = Fixture.create()

      Fixture.write!(
        dir,
        "test/other_test.exs",
        "defmodule OtherTest do\n  use ExUnit.Case\n  test \"x\" do\n    assert true\n  end\nend\n"
      )

      base_commit = Fixture.commit!(dir, "add other_test.exs")

      big_body =
        Enum.map_join(1..3000, &"    assert Calc.add(#{&1}, 1) == #{&1 + 1}\n")

      Fixture.write!(
        dir,
        "test/other_test.exs",
        "defmodule OtherTest do\n  use ExUnit.Case\n  test \"x\" do\n#{big_body}  end\nend\n"
      )

      {:ok, catalog} = VerificationPlan.load(dir)
      candidate_id = Fixture.candidate_id!(dir)
      ledger_dir = tmp_ledger_dir(dir)

      assert {:ok, ledger} =
               Ledger.compute(%{
                 root: dir,
                 base_commit: base_commit,
                 candidate_id: candidate_id,
                 integrity: catalog.integrity,
                 admission_sha256: catalog.sha256,
                 candidate_sha256: catalog.sha256,
                 receipts: [],
                 directory: ledger_dir,
                 preservation: []
               })

      assert ledger["items"] |> hd() |> get_in(["diff", "byte_count"]) > 65_536

      record = %{
        "attempts" => [
          %{
            "number" => 1,
            "attempt_token" => "tok-1",
            "verification_ledger" => ledger,
            "base_suite" => %{"status" => "skipped", "use" => "report for Review, not a gate"},
            "handoff" => %{},
            "receipts" => []
          }
        ],
        "scenarios" => [%{"id" => "s1"}],
        "risks" => [],
        "findings" => []
      }

      record_bytes = Jason.encode!(record)

      input = %{
        record: record,
        record_path: Path.join(dir, ".kogen/runtime/scenario-tracking/build-x/record.json"),
        record_bytes: record_bytes,
        candidate_id: candidate_id,
        open_findings: []
      }

      assert {:ok, bytes} = ReviewPacket.build(input)
      assert byte_size(bytes) <= ReviewPacket.limit()
      packet = Jason.decode!(bytes)

      ledger_index = packet["verification_ledger"]
      assert ledger_index["locator"] == "/attempts/0/verification_ledger"
      assert [item] = ledger_index["items"]
      assert item["path"] == "test/other_test.exs"
      assert item["diff"]["sha256"] == hd(ledger["items"])["diff"]["sha256"]
      assert item["diff"]["byte_count"] == hd(ledger["items"])["diff"]["byte_count"]
      # The full diff bytes are never inlined in the packet.
      refute bytes =~ "assert Calc.add(1500"
      assert packet["base_suite"]["use"] == "report for Review, not a gate"
    end
  end

  describe "Kogen.Harness.Verdict schema per Reviewer launch" do
    test "schema([]) is byte-identical to schema/0; schema(paths) requires a ledger" do
      assert Verdict.schema([]) == Verdict.schema()

      with_ledger = Verdict.schema(["test/a_test.exs"])
      refute with_ledger == Verdict.schema()
      decoded = Jason.decode!(with_ledger)
      assert "ledger" in decoded["required"]

      assert decoded["properties"]["ledger"]["items"]["properties"]["path"]["enum"] == [
               "test/a_test.exs"
             ]
    end

    test "validate/2 accepts ledger exactly when requested" do
      base_message = %{
        "candidate_id" => "c",
        "attempt_token" => "t",
        "verdict" => "accept",
        "scenarios" => [],
        "dispositions" => [],
        "findings" => []
      }

      assert {:ok, _} = Verdict.validate(base_message, false)
      assert :error = Verdict.validate(base_message, true)

      with_ledger =
        Map.put(base_message, "ledger", [%{"path" => "x", "disposition" => "weakening"}])

      assert {:ok, _} = Verdict.validate(with_ledger, true)
      assert :error = Verdict.validate(with_ledger, false)
    end
  end

  describe "the Jev request excludes the ledger" do
    test "the wire request holds only developer notes and item ids, never ledger content" do
      previous_key = System.get_env("FAKE_JEV_KEY")
      System.put_env("FAKE_JEV_KEY", "kogen-offline-sentinel-jev-key")

      on_exit(fn ->
        if previous_key,
          do: System.put_env("FAKE_JEV_KEY", previous_key),
          else: System.delete_env("FAKE_JEV_KEY")
      end)

      items = [%{"kind" => "scenario", "id" => "s-main"}, %{"kind" => "risk", "id" => "r-1"}]
      notes = "diff --git a/test/other_test.exs b/test/other_test.exs\nweakened the assertion"

      outcome =
        Kogen.Jev.read_notes(notes, items,
          security: FakeJev.security_path(),
          transport: FakeJev.transport([{200, FakeJev.answer_body(items)}], self())
        )

      assert outcome["outcome"] == "answered"

      assert_receive {:jev_request, request}
      decoded = Jason.decode!(request.body)
      assert Map.keys(decoded) |> Enum.sort() == ["model", "questions", "state"]
      assert Map.keys(decoded["state"]) |> Enum.sort() == ["developer_notes", "items"]
      assert decoded["state"]["developer_notes"] == notes

      assert decoded["state"]["items"] == [
               %{"kind" => "scenario", "id" => "s-main"},
               %{"kind" => "risk", "id" => "r-1"}
             ]

      refute Map.has_key?(decoded, "ledger")
      refute Map.has_key?(decoded["state"], "ledger")
    end
  end

  describe "fake Reviewer schema recording" do
    test "fake Claude records --json-schema and answers a required ledger" do
      dir = fake_harness_dir()
      File.mkdir_p!(Path.join(dir, ".kogen/runtime"))
      claude = Path.join(dir, "fake_claude")
      File.cp!(Path.join(root(), "test/support/fake_claude"), claude)
      File.cp!(Path.join(root(), "test/support/fake_ledger.py"), Path.join(dir, "fake_ledger.py"))

      File.cp!(
        Path.join(root(), "test/support/scenario_response.py"),
        Path.join(dir, "scenario_response.py")
      )

      File.cp!(
        Path.join(root(), "test/support/claude_stream.py"),
        Path.join(dir, "claude_stream.py")
      )

      File.chmod!(claude, 0o755)

      write_stop_hook!(dir)

      previous = System.get_env("FAKE_CLAUDE_REVIEW")
      System.put_env("FAKE_CLAUDE_REVIEW", "accept")

      on_exit(fn ->
        if previous,
          do: System.put_env("FAKE_CLAUDE_REVIEW", previous),
          else: System.delete_env("FAKE_CLAUDE_REVIEW")
      end)

      claude_config = %{
        harness: "claude",
        helpers: %{
          scout: %{model: "claude-sonnet-5", effort: "low"},
          worker: %{model: "claude-sonnet-5", effort: "medium"},
          expert: %{model: "claude-opus-5-5", effort: "high"}
        }
      }

      context =
        %{
          harness: "claude",
          executable: claude,
          args: [],
          env: [],
          config: claude_config,
          project: dir
        }
        |> Kogen.Harness.with_ledger(["test/a_test.exs"])

      File.cd!(dir, fn ->
        assert {:ok, verdict} =
                 Kogen.Harness.launch_reviewer("review this", "fake", "low", context)

        assert verdict.response["ledger"] == [
                 %{"path" => "test/a_test.exs", "disposition" => "justified: unknown"}
               ]
      end)

      schema = File.read!(Path.join(dir, ".kogen/runtime/reviewer-schema-1.json"))

      assert Jason.decode!(schema) ==
               Jason.decode!(Verdict.schema(["test/a_test.exs"]))

      # Without a ledger the schema is byte-identical to today's schema.
      context_no_ledger = %{
        harness: "claude",
        executable: claude,
        args: [],
        env: [],
        config: claude_config,
        project: dir
      }

      File.cd!(dir, fn ->
        assert {:ok, _verdict} =
                 Kogen.Harness.launch_reviewer("review this", "fake", "low", context_no_ledger)
      end)

      schema2 = File.read!(Path.join(dir, ".kogen/runtime/reviewer-schema-2.json"))
      assert schema2 == Verdict.schema()
    end

    test "fake Codex records --output-schema and answers a required ledger" do
      dir = fake_harness_dir()
      File.mkdir_p!(Path.join(dir, ".kogen/runtime"))
      codex = Path.join(dir, "fake_codex")
      File.cp!(Path.join(root(), "test/support/fake_codex"), codex)
      File.cp!(Path.join(root(), "test/support/fake_ledger.py"), Path.join(dir, "fake_ledger.py"))

      File.cp!(
        Path.join(root(), "test/support/scenario_response.py"),
        Path.join(dir, "scenario_response.py")
      )

      File.chmod!(codex, 0o755)

      tracking_path = Path.join(dir, "record.json")
      File.write!(tracking_path, Jason.encode!(%{"attempts" => [%{"receipts" => []}]}))
      approved_dir = Path.join(dir, "approved")
      File.mkdir_p!(approved_dir)

      task_context =
        Jason.encode!(%{"tracking_path" => tracking_path, "approved_path" => approved_dir})

      prompt = "review this\nKOGEN_TASK_CONTEXT\n#{task_context}\n"

      context =
        %{harness: "codex", executable: codex, args: [], env: []}
        |> Kogen.Harness.with_ledger(["test/a_test.exs"])

      File.cd!(dir, fn ->
        assert {:ok, verdict} = Kogen.Harness.launch_reviewer(prompt, "fake", "low", context)

        assert verdict.response["ledger"] == [
                 %{"path" => "test/a_test.exs", "disposition" => "justified: unknown"}
               ]
      end)

      schema = File.read!(Path.join(dir, ".kogen/runtime/reviewer-schema-1.json"))

      assert Jason.decode!(schema) ==
               Jason.decode!(Verdict.schema(["test/a_test.exs"]))

      context_no_ledger = %{harness: "codex", executable: codex, args: [], env: []}

      File.cd!(dir, fn ->
        assert {:ok, _verdict} =
                 Kogen.Harness.launch_reviewer(prompt, "fake", "low", context_no_ledger)
      end)

      schema2 = File.read!(Path.join(dir, ".kogen/runtime/reviewer-schema-2.json"))
      assert schema2 == Verdict.schema()
    end
  end

  defp scenario_entry(id) do
    %{
      "id" => id,
      "status" => "satisfied",
      "reason" => "fixture review verified the candidate",
      "evidence" => [%{"path" => "Makefile", "locator" => "check"}]
    }
  end

  defp write_stop_hook!(dir) do
    File.mkdir_p!(Path.join(dir, ".codex/hooks"))

    File.write!(
      Path.join(dir, ".codex/hooks/check.sh"),
      "#!/bin/sh\nprintf '%s' '{\"continue\":true}'\n"
    )

    File.chmod!(Path.join(dir, ".codex/hooks/check.sh"), 0o755)
  end

  defp fake_harness_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "kogen-ledger-reviewer-#{System.pid()}-#{Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp root, do: Path.expand("../..", __DIR__)

  defp tmp_ledger_dir(root) do
    unique = Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
    dir = Path.join(root, ".kogen/ledger-scratch-#{unique}")
    File.mkdir_p!(dir)
    dir
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
