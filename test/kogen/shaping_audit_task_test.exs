Code.require_file("../support/shaping_audit/fixture.ex", __DIR__)
Code.require_file("../support/compiled_fixture.exs", __DIR__)

defmodule Kogen.ShapingAuditTaskTest do
  use Kogen.IsolatedCase, async: true
  alias Kogen.ShapingAudit.{Fixture, Package, Report}
  @root Path.expand("../..", __DIR__)

  defp repo!(opts \\ []) do
    root = Fixture.repo!(opts)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp add!(root, slug, opts \\ []), do: Fixture.add_draft!(root, slug, opts)

  defp intent_manifest(root) do
    root
    |> Path.join(".kogen/intents")
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.sort()
    |> Enum.reduce(:crypto.hash_init(:sha256), fn relative, state ->
      state
      |> :crypto.hash_update(relative)
      |> :crypto.hash_update(<<0>>)
      |> :crypto.hash_update(File.read!(Path.join(root, relative)))
      |> :crypto.hash_update(<<0>>)
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp call(root, args, opts \\ []) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    io = %{
      puts: fn line -> Agent.update(agent, &[{:out, line} | &1]) end,
      err: fn line -> Agent.update(agent, &[{:err, line} | &1]) end
    }

    audit_args = if "--status" in args, do: args, else: ["--auditor" | args]

    code =
      Kogen.ShapingAudit.main(
        audit_args,
        [root: root, env: Fixture.audit_env!(root), io: io] ++ opts
      )

    output = Agent.get(agent, &Enum.reverse/1)
    Agent.stop(agent)
    {code, output}
  end

  test "a ready audit exits 0, writes the report layout, and leaves .kogen/intents and tmp untouched" do
    root = repo!()
    add!(root, "complete")

    before = intent_manifest(root)
    own_prefix = "kogen-audit-#{:erlang.phash2(self())}-"

    own_tmp_entries = fn ->
      Path.wildcard(Path.join(System.tmp_dir!(), "kogen-audit-*"))
      |> Enum.filter(&(Path.basename(&1) |> String.starts_with?(own_prefix)))
    end

    tmp_before = own_tmp_entries.()

    assert {0, _} = call(root, ["complete"])
    {:ok, rel} = Package.locate(root, "complete")
    {:ok, loaded} = Package.load(root, rel)

    assert {:ok, report} = Report.read(root, "complete", loaded.revision)

    assert Map.keys(report) |> Enum.sort() ==
             ~w(findings head layers not_audited_by_auditor package questions readiness revision route schema_version slug state)

    assert report["schema_version"] == 2
    assert report["slug"] == "complete"
    assert report["package"] == rel
    assert report["revision"] == loaded.revision
    assert report["head"] == Fixture.head(root)
    assert report["route"] == "codex"
    assert report["layers"]["deterministic"] == %{"status" => "ok"}
    assert report["layers"]["auditor"]["status"] == "ok"
    assert report["layers"]["jev"]["status"] == "ok"
    assert report["findings"] == []
    assert report["readiness"] == "ready"
    assert File.regular?(Path.join(Report.dir(root, "complete", loaded.revision), "report.json"))
    assert File.regular?(Path.join(Report.dir(root, "complete", loaded.revision), "report.md"))
    markdown = File.read!(Path.join(Report.dir(root, "complete", loaded.revision), "report.md"))
    assert markdown =~ "ready"

    after_hash = intent_manifest(root)

    assert before == after_hash
    assert own_tmp_entries.() == tmp_before
  end

  test "--status is current, then stale after a commit, then stale for another route, then missing after an edit" do
    root = repo!()
    add!(root, "complete")
    assert {0, _} = call(root, ["complete"])
    assert {0, out} = call(root, ["--status", "complete"])
    assert {:out, "current"} in out
    File.write!(Path.join(root, "unrelated.txt"), "x")
    System.cmd("git", ["add", "unrelated.txt"], cd: root)
    System.cmd("git", ["commit", "-q", "-m", "unrelated"], cd: root)
    assert {1, out} = call(root, ["--status", "complete"])
    assert Enum.any?(out, &match?({:out, "stale: head"}, &1))
    assert {1, out} = call(root, ["--status", "--route", "other", "complete"])

    assert Enum.any?(out, fn
             {:out, line} -> String.contains?(line, "route")
             _ -> false
           end)

    before_reports =
      Path.wildcard(Path.join(root, ".kogen/runtime/shaping-audits/**/*/report.json"))

    File.write!(Path.join(root, ".kogen/intents/drafts/complete/INTENT.md"), "# edited\n")
    assert {1, out} = call(root, ["--status", "complete"])
    assert {:out, "missing"} in out

    assert Path.wildcard(Path.join(root, ".kogen/runtime/shaping-audits/**/*/report.json")) ==
             before_reports
  end

  for role <- ~w(developer reviewer expert auditor) do
    test "refuses role #{role}: exit 2, no report, no materialization, no read" do
      root = repo!()
      add!(root, "complete")

      reads = Agent.start_link(fn -> [] end) |> elem(1)

      read = fn path ->
        Agent.update(reads, &[path | &1])
        File.read(path)
      end

      assert 2 =
               Kogen.ShapingAudit.main(["--auditor", "complete"],
                 root: root,
                 env: Map.merge(Fixture.audit_env!(root), %{"KOGEN_ROLE" => unquote(role)}),
                 read: read
               )

      assert Agent.get(reads, & &1) == []
      assert Path.wildcard(Path.join(root, ".kogen/runtime/shaping-audits/complete/**/*")) == []
    end
  end

  test "refuses while .kogen/build.lock is present, for an ambiguous slug, a missing slug and a bad argument" do
    root = repo!()
    add!(root, "complete")
    reads = Agent.start_link(fn -> [] end) |> elem(1)

    read = fn path ->
      Agent.update(reads, &[path | &1])
      File.read(path)
    end

    File.mkdir_p!(Path.join(root, ".kogen"))
    File.write!(Path.join(root, ".kogen/build.lock"), "x")
    assert {2, _} = call(root, ["complete"], read: read)
    assert Agent.get(reads, & &1) == []

    root_dir_link = repo!()
    package = add!(root_dir_link, "complete")
    real_package = Path.join(root_dir_link, ".kogen/intents/drafts/complete-real")
    File.rename!(Path.join(root_dir_link, package), real_package)
    File.ln_s!("complete-real", Path.join(root_dir_link, package))
    assert {2, output} = call(root_dir_link, ["complete"], read: read)

    assert Enum.any?(output, fn
             {:err, line} -> String.contains?(line, "complete")
             _ -> false
           end)

    assert Agent.get(reads, & &1) == []
    File.rm!(Path.join(root, ".kogen/build.lock"))
    Fixture.add_draft!(root, "complete", dir: "approved")
    assert {2, _} = call(root, ["complete"], read: read)
    assert Agent.get(reads, & &1) == []
    assert {2, _} = call(root, ["missing"], read: read)
    assert Agent.get(reads, & &1) == []
    assert {2, _} = call(root, ["--nope", "complete"], read: read)
    assert Agent.get(reads, & &1) == []
    assert Path.wildcard(Path.join(root, ".kogen/runtime/shaping-audits/**/*")) == []
  end

  test "non-regular package entries are refused before anything is read" do
    root = repo!()
    add!(root, "complete")
    reads = Agent.start_link(fn -> [] end) |> elem(1)

    read = fn path ->
      Agent.update(reads, &[path | &1])
      File.read(path)
    end

    File.rm!(Path.join(root, ".kogen/intents/drafts/complete/scenarios.yaml"))
    File.ln_s!("intent.yaml", Path.join(root, ".kogen/intents/drafts/complete/scenarios.yaml"))
    assert {2, output} = call(root, ["complete"], read: read)

    assert Enum.any?(output, fn
             {:err, line} -> is_binary(line) and String.contains?(line, "scenarios.yaml")
             _ -> false
           end)

    assert Agent.get(reads, & &1) == []

    root_fifo = repo!()
    add!(root_fifo, "complete")
    fifo = Path.join(root_fifo, ".kogen/intents/drafts/complete/fifo")
    {_, 0} = System.cmd("mkfifo", [fifo])
    assert {2, output} = call(root_fifo, ["complete"], read: read)

    assert Enum.any?(output, fn
             {:err, line} -> is_binary(line) and String.contains?(line, "fifo")
             _ -> false
           end)

    assert Agent.get(reads, & &1) == []

    root_link = repo!()
    add!(root_link, "non-regular")
    link = Path.join(root_link, ".kogen/intents/drafts/non-regular/link.txt")
    File.ln_s!("target.txt", link)
    assert {2, output} = call(root_link, ["non-regular"], read: read)

    assert Enum.any?(output, fn
             {:err, line} -> is_binary(line) and String.contains?(line, "link.txt")
             _ -> false
           end)

    assert Agent.get(reads, & &1) == []
  end

  test "an approved-only package runs normally" do
    root = repo!()
    Fixture.add_draft!(root, "complete", dir: "approved")
    assert {0, _} = call(root, ["complete"])
  end

  test "H26 inside a Shaping session a manual run audits nothing and prints the hook status" do
    root = repo!()
    package_rel = add!(root, "complete")
    shaper_env = Map.put(Fixture.audit_env!(root), "KOGEN_ROLE", "shaper")

    first_line =
      "Inside a Shaping session the Stop hook audits the Draft at every stop: end your turn to re-audit"

    parent = self()
    io = %{puts: &send(parent, {:out, &1}), err: &send(parent, {:err, &1})}

    lines = fn ->
      Stream.repeatedly(fn ->
        receive do
          message -> message
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(& &1)
    end

    for args <- [["complete"], ["--auditor", "complete"], ["--status", "complete"]] do
      assert Kogen.ShapingAudit.main(args, root: root, env: shaper_env, io: io) == 1
      assert lines.() == [{:out, first_line}, {:out, "last hook report: missing"}], inspect(args)
      refute File.exists?(Path.join(root, ".kogen/runtime/shaping-audits"))
      refute File.exists?(shaper_env["FAKE_AUDITOR_LOG_DIR"])
    end

    output = Path.join(root, "hook-output.json")

    hook_env =
      Map.merge(shaper_env, %{
        "KOGEN_SHAPING_INTENT_ID" => "01965000-0000-7000-8000-00000000c001",
        "KOGEN_SHAPING_ROUTE" => "codex",
        "KOGEN_SHAPING_HOOK_OUTPUT" => output
      })

    assert Kogen.ShapingAudit.main(["--stop-hook"], root: root, env: hook_env, io: io, stdin: "") ==
             0

    assert %{"continue" => true, "systemMessage" => "ready: " <> _} =
             output |> File.read!() |> Jason.decode!()

    {:ok, %{revision: revision}} = Package.load(root, package_rel)
    assert Kogen.ShapingAudit.main(["complete"], root: root, env: shaper_env, io: io) == 0

    assert lines.() == [
             {:out, first_line},
             {:out, "last hook report: ready (revision #{revision})"}
           ]

    audits = Path.join(root, ".kogen/runtime/shaping-audits/complete")

    assert Path.wildcard(Path.join(audits, "*/report.json")) == [
             Path.join([audits, revision, "report.json"])
           ]

    assert length(Path.wildcard(Path.join(audits, "auditor/*.json"))) == 1
    assert File.exists?(Path.join(shaper_env["FAKE_AUDITOR_LOG_DIR"], "argv"))
  end

  test "the mix task only delegates to the entry function and halts with its code" do
    source = File.read!(Path.join(@root, "lib/mix/tasks/kogen.audit.ex"))
    assert source =~ "System.halt(Kogen.ShapingAudit.main(args))"
    root = repo!(compiled: true)
    add!(root, "complete")

    {output, 0} =
      Kogen.CompiledFixture.mix_task!(root, ["kogen.audit", "--auditor", "complete"], [
        {"KOGEN_ROLE", nil},
        {"KOGEN_HARNESS_HOME", nil},
        {"KOGEN_HARNESS", Path.join(@root, "test/support/shaping_audit/fake_auditor")},
        {"KOGEN_JEV_TRANSPORT", Path.join(@root, "test/support/shaping_audit/fake_jev_audit")},
        {"KOGEN_JEV_SECURITY",
         Path.join(@root, "test/support/shaping_audit/fake_security_audit")},
        {"FAKE_AUDITOR_LOG_DIR", Path.join(root, ".kogen/runtime/fake-auditor")},
        {"FAKE_JEV_LOG_DIR", Path.join(root, ".kogen/runtime/fake-jev-audit")},
        {"FAKE_AUDITOR_MESSAGE", "empty"},
        {"FAKE_JEV_ANSWERS", nil}
      ])

    assert output =~ "ready"
    {:ok, rel} = Package.locate(root, "complete")
    {:ok, %{revision: revision}} = Package.load(root, rel)
    assert {:ok, %{"readiness" => "ready"}} = Report.read(root, "complete", revision)

    {_output, 2} =
      Kogen.CompiledFixture.mix_task!(root, ["kogen.audit", "--nope", "complete"], [
        {"KOGEN_ROLE", nil},
        {"KOGEN_HARNESS_HOME", nil}
      ])
  end

  test "the README documents the command, the report layout, readiness and that a report is never approval" do
    text = File.read!(Path.join(@root, "README.md")) |> String.replace(~r/\s+/, " ")

    for fragment <- [
          "### Shaping audit",
          "mix kogen.audit [--route <name>] <slug>",
          "mix kogen.audit --status",
          ".kogen/runtime/shaping-audits/<slug>/<revision>/",
          "exits `0` when",
          "A report is never approval"
        ] do
      assert text =~ fragment
    end
  end
end
