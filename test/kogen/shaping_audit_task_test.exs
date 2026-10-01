Code.require_file("../support/shaping_audit/fixture.ex", __DIR__)
Code.require_file("../support/compiled_fixture.exs", __DIR__)

defmodule Kogen.ShapingAuditTaskTest do
  use Kogen.IsolatedCase, async: true
  alias Kogen.ShapingAudit.{Auditor, Fixture, Package, Report}
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

    audit_args =
      if "--status" in args or "--confirm" in args, do: args, else: ["--auditor" | args]

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
             ~w(config_fingerprint findings head layers not_audited_by_auditor package questions readiness revision route schema_version scope slug state)

    assert report["schema_version"] == 3
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

  test "early external confirmation refuses at zero or one normal attempt without launch or cache success" do
    root = repo!()
    package_rel = add!(root, "complete")
    ledger = Path.join(root, ".kogen/runtime/shaping-audits/complete/auditor")
    auditor_log = Path.join(root, ".kogen/runtime/fake-auditor")
    jev_log = Path.join(root, ".kogen/runtime/fake-jev-audit")
    assert {2, output} = call(root, ["--confirm", "complete"])

    assert Enum.any?(output, fn {channel, text} ->
             channel == :err and text =~ "exhausted normal auditor budget"
           end)

    assert Path.wildcard(Path.join(ledger, "*")) == []

    File.write!(
      Path.join([root, package_rel, "intent.yaml"]),
      "\n# changed before any attempt\n",
      [:append]
    )

    assert {2, _} = call(root, ["--confirm", "complete"])
    assert Path.wildcard(Path.join(ledger, "*")) == []
    refute File.exists?(auditor_log)
    refute File.exists?(jev_log)

    assert {0, _} = call(root, ["complete"])
    {:ok, first} = Package.load(root, package_rel)
    report_path = Path.join(Report.dir(root, "complete", first.revision), "report.json")
    report_bytes = File.read!(report_path)
    ledger_bytes = Map.new(Path.wildcard(Path.join(ledger, "*")), &{&1, File.read!(&1)})
    File.rm_rf!(auditor_log)
    File.rm_rf!(jev_log)
    assert {2, _} = call(root, ["--confirm", "complete"])
    assert File.read!(report_path) == report_bytes
    assert {:ok, %{"readiness" => "ready"}} = Report.read(root, "complete", first.revision)

    assert {:error, :confirmation_before_bound} =
             Kogen.ShapingAudit.audit(root, %{
               slug: "complete",
               auditor: true,
               confirm?: true,
               reuse: true
             })

    File.write!(Path.join([root, package_rel, "intent.yaml"]), "\n# second revision\n", [:append])
    assert {2, _} = call(root, ["--confirm", "complete"])
    assert ledger_bytes == Map.new(Path.wildcard(Path.join(ledger, "*")), &{&1, File.read!(&1)})
    refute File.exists?(auditor_log)
    refute File.exists?(jev_log)
    {:ok, second} = Package.load(root, package_rel)
    assert Report.read(root, "complete", second.revision) == {:error, :missing}

    # Normal scheduling remains available; after its bound the explicit
    # grant and its exact replay retain their existing behavior.
    assert {0, _} = call(root, ["complete"])
    assert {0, _} = call(root, ["--confirm", "complete"])
    {:ok, confirmed} = Report.read(root, "complete", second.revision)
    assert confirmed["layers"]["auditor"]["budget_state"]["normal_count"] == 2
    assert confirmed["layers"]["auditor"]["budget_state"]["confirmation_grant"] == "used"
    File.rm_rf!(auditor_log)
    assert {0, _} = call(root, ["--confirm", "complete"])
    {:ok, replayed} = Report.read(root, "complete", second.revision)

    assert replayed["layers"]["auditor"]["attempt_id"] ==
             confirmed["layers"]["auditor"]["attempt_id"]

    refute File.exists?(auditor_log)
    assert length(Path.wildcard(Path.join(ledger, "*.json"))) == 3
  end

  test "legacy completion symlinks and nonregular entries fail closed before confirmation dispatch" do
    for kind <- [:dangling_symlink, :live_symlink, :directory, :fifo] do
      root = repo!()
      package_rel = add!(root, "complete")
      {:ok, package} = Package.load(root, package_rel)
      {:ok, config} = Kogen.Intent.read_config(Path.join(root, ".kogen/config.yaml"), nil)
      ledger = Path.join(root, ".kogen/runtime/shaping-audits/complete/auditor")
      File.mkdir_p!(ledger)

      legacy = %{
        "schema_version" => 1,
        "revision" => package.revision,
        "head" => Fixture.head(root),
        "route" => config.route,
        "status" => "ok",
        "findings" => [],
        "counted" => true,
        "confirmation_grant" => false,
        "recorded_at" => DateTime.to_iso8601(DateTime.utc_now())
      }

      for seq <- 1..2 do
        File.write!(
          Path.join(ledger, "legacy-#{seq}.json"),
          Jason.encode!(Map.put(legacy, "seq", seq))
        )
      end

      uncounted =
        legacy
        |> Map.put("counted", false)
        |> Map.put("seq", nil)
        |> Map.put("status", "unavailable")

      File.write!(Path.join(ledger, "uncounted.json"), Jason.encode!(uncounted))
      ctx = %{root: root, slug: "complete", route: config.route, head: legacy["head"]}
      assert length(Auditor.load_records(ctx)) == 3
      ledger_bytes = Map.new(Path.wildcard(Path.join(ledger, "*.json")), &{&1, File.read!(&1)})
      completion = Path.join(ledger, "legacy-1.json.completion")

      case kind do
        :dangling_symlink -> File.ln_s!(Path.join(root, "missing-completion"), completion)
        :live_symlink -> File.ln_s!(Path.join(ledger, "legacy-2.json"), completion)
        :directory -> File.mkdir!(completion)
        :fifo -> {_, 0} = System.cmd("mkfifo", [completion])
      end

      assert {:error, _} = Auditor.load_records(ctx)
      assert {1, _} = call(root, ["--confirm", "complete"])
      {:ok, report} = Report.read(root, "complete", package.revision)
      assert report["layers"]["auditor"]["status"] == "unavailable"
      assert report["layers"]["auditor"]["reason"] =~ "legacy attempt has unexpected completion"
      refute File.exists?(Path.join(root, ".kogen/runtime/fake-auditor/argv"))

      assert ledger_bytes ==
               Map.new(Path.wildcard(Path.join(ledger, "*.json")), &{&1, File.read!(&1)})

      assert {:ok, _} = File.lstat(completion)
    end
  end

  test "the external CLI confirmation uses one extra grant after the normal budget" do
    root = repo!()
    package_rel = add!(root, "complete")

    assert {0, _} = call(root, ["complete"])
    File.write!(Path.join([root, package_rel, "intent.yaml"]), "\n# second revision\n", [:append])
    assert {0, _} = call(root, ["complete"])

    File.write!(Path.join([root, package_rel, "intent.yaml"]), "\n# third revision\n", [:append])
    assert {1, _} = call(root, ["complete"])

    {:ok, current} = Package.load(root, package_rel)
    assert {:ok, not_ready} = Report.read(root, "complete", current.revision)
    assert not_ready["layers"]["auditor"]["status"] == "missing-confirmation"
    assert not_ready["layers"]["auditor"]["budget_state"]["normal_count"] == 2
    markdown = File.read!(Path.join(Report.dir(root, "complete", current.revision), "report.md"))
    assert markdown =~ "## Auditor budget"
    assert markdown =~ "normal runs: 2/2 (exhausted)"
    assert markdown =~ "confirmation grant: available"

    assert {0, _} = call(root, ["--confirm", "complete"])
    {:ok, confirmed} = Report.read(root, "complete", current.revision)
    assert confirmed["readiness"] == "ready"
    assert confirmed["layers"]["auditor"]["budget_state"]["confirmation_grant"] == "used"

    File.write!(Path.join([root, package_rel, "intent.yaml"]), "\n# fourth revision\n", [:append])
    assert {1, _} = call(root, ["--confirm", "complete"])
    {:ok, exhausted_revision} = Package.load(root, package_rel)
    assert {:ok, exhausted} = Report.read(root, "complete", exhausted_revision.revision)
    assert exhausted["layers"]["auditor"]["status"] == "missing-confirmation"
    assert exhausted["layers"]["auditor"]["budget_state"]["confirmation_grant"] == "used"
  end

  test "valid explicit confirmation consumes its grant when the auditor configuration is missing" do
    root = repo!()
    package_rel = add!(root, "complete")
    assert {0, _} = call(root, ["complete"])
    File.write!(Path.join([root, package_rel, "intent.yaml"]), "\n# second revision\n", [:append])
    assert {0, _} = call(root, ["complete"])
    config_path = Path.join(root, ".kogen/config.yaml")
    config = File.read!(config_path)
    File.write!(config_path, String.replace(config, ~r/^\s+auditor:.*\n/m, ""))
    assert {1, _} = call(root, ["--confirm", "complete"])
    {:ok, current} = Package.load(root, package_rel)
    {:ok, unavailable} = Report.read(root, "complete", current.revision)
    assert unavailable["layers"]["auditor"]["status"] == "unavailable"
    assert unavailable["layers"]["auditor"]["reason"] =~ "no auditor setting"
    assert unavailable["layers"]["auditor"]["budget_state"]["confirmation_grant"] == "used"
    assert unavailable["layers"]["auditor"]["budget_state"]["normal_count"] == 2

    File.write!(config_path, config)
    File.rm_rf!(Path.join(root, ".kogen/runtime/fake-auditor"))
    assert {1, _} = call(root, ["--confirm", "complete"])
    {:ok, replayed} = Report.read(root, "complete", current.revision)

    assert replayed["layers"]["auditor"]["status"] == "missing-confirmation"
    assert replayed["layers"]["auditor"]["attempt_id"] == nil
    assert replayed["layers"]["auditor"]["budget_state"]["confirmation_grant"] == "used"
    assert replayed["layers"]["auditor"]["budget_state"]["normal_count"] == 2
    refute File.exists?(Path.join(root, ".kogen/runtime/fake-auditor/argv"))
  end

  test "--confirm rejects incompatible modes and the managed shaping role" do
    root = repo!()
    add!(root, "complete")
    reads = Agent.start_link(fn -> [] end) |> elem(1)

    read = fn path ->
      Agent.update(reads, &[path | &1])
      File.read(path)
    end

    for args <- [
          ["--confirm", "--auditor", "complete"],
          ["--confirm", "--status", "complete"],
          ["--confirm", "--stop-hook"]
        ] do
      assert 2 =
               Kogen.ShapingAudit.main(args,
                 root: root,
                 env: Fixture.audit_env!(root),
                 read: read
               )
    end

    assert 2 =
             Kogen.ShapingAudit.main(["--confirm", "complete"],
               root: root,
               env: Map.put(Fixture.audit_env!(root), "KOGEN_ROLE", "shaping"),
               read: read
             )

    assert Agent.get(reads, & &1) == []
    refute File.exists?(Path.join(root, ".kogen/runtime/shaping-audits"))
  end

  test "H26 inside a Shaping session a manual run audits nothing and prints the hook status" do
    root = repo!()
    package_rel = add!(root, "complete")
    shaper_env = Map.put(Fixture.audit_env!(root), "KOGEN_ROLE", "shaping")

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

  defp fixture_elixir_args do
    ebins =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.filter(&(Path.type(&1) == :absolute and Path.basename(&1) == "ebin"))

    ["--erl", "+S 2:2 +SDcpu 1 +SDio 1"] ++ Enum.flat_map(ebins, &["-pa", &1])
  end

  test "independent VMs mint distinct paths for an identical attempt binding" do
    code =
      ~s|IO.puts(Kogen.ShapingAudit.Auditor.record_path("root", "slug", "revision", "route", "head", 1))|

    paths =
      for _ <- 1..2 do
        {output, 0} = System.cmd("elixir", fixture_elixir_args() ++ ["-e", code])
        String.trim(output)
      end

    assert length(Enum.uniq(paths)) == 2
  end

  test "a killed public confirmation remains consumed and never dispatches on retry" do
    root = repo!(compiled: true)
    package_rel = add!(root, "complete")
    assert {0, _} = call(root, ["complete"])
    File.write!(Path.join([root, package_rel, "intent.yaml"]), "\n# second revision\n", [:append])
    assert {0, _} = call(root, ["complete"])
    {:ok, current} = Package.load(root, package_rel)
    barrier = Path.join(root, ".kogen/provider-barrier.json")
    counter = Path.join(root, ".kogen/provider-launches")
    wrapper = Path.join(root, ".kogen/barrier-auditor")

    File.write!(wrapper, """
    #!/usr/bin/env python3
    import json, os, sys, time
    sys.stdin.buffer.read()
    with open(#{inspect(counter)}, "a") as f:
        f.write("launch\\n")
    with open(#{inspect(barrier)} + ".tmp", "w") as f:
        json.dump({"pid": os.getpid()}, f)
    os.replace(#{inspect(barrier)} + ".tmp", #{inspect(barrier)})
    while True:
        time.sleep(0.02)
    """)

    File.chmod!(wrapper, 0o755)
    env = Fixture.audit_env!(root) |> Map.put("KOGEN_HARNESS", wrapper)

    # The supervisor always settles its owned CLI and barrier provider,
    # including readiness/assertion failure and outer Port closure.
    supervisor = """
    import json, os, signal, subprocess, sys, time
    root, marker = sys.argv[1:3]
    child = subprocess.Popen(sys.argv[3:], cwd=root, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, start_new_session=True)
    try:
        deadline = time.monotonic() + 20
        while not os.path.exists(marker):
            if child.poll() is not None:
                raise RuntimeError(child.communicate()[0].decode())
            if time.monotonic() > deadline:
                raise RuntimeError("provider barrier timed out")
            time.sleep(0.02)
        print("barrier", flush=True)
        sys.stdin.readline()
    finally:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        if os.path.exists(marker):
            with open(marker) as f:
                provider = json.load(f)["pid"]
            try:
                os.kill(provider, signal.SIGKILL)
            except ProcessLookupError:
                pass
        child.wait(timeout=10)
    """

    args =
      ["-B", "-c", supervisor, root, barrier, System.find_executable("elixir")] ++
        fixture_elixir_args() ++ ["-S", "mix", "kogen.audit", "--confirm", "complete"]

    port =
      Port.open({:spawn_executable, System.find_executable("python3")}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:line, 4096},
        args: args,
        env:
          Enum.map(env, fn {key, value} ->
            {String.to_charlist(key), String.to_charlist(value)}
          end)
      ])

    try do
      assert_receive {^port, {:data, {:eol, "barrier"}}}, 25_000

      records =
        Path.wildcard(Path.join(root, ".kogen/runtime/shaping-audits/complete/auditor/*.json"))

      reservations = Enum.map(records, &(File.read!(&1) |> Jason.decode!()))
      grant = Enum.find(reservations, & &1["confirmation_grant"])
      assert grant["phase"] == "reserved"
      assert grant["counted"]
      assert grant["effects"] == "unknown"
      assert length(records) == 3
      assert length(Enum.uniq(Enum.map(reservations, & &1["attempt_id"]))) == 3
      grant_path = Enum.find(records, &(Path.basename(&1) == grant["attempt_id"] <> ".json"))
      refute File.exists?(grant_path <> ".completion")
      assert Report.read(root, "complete", current.revision) == {:error, :missing}

      assert Report.status(root, "complete", current.revision, grant["head"], grant["route"]) ==
               :missing

      Port.command(port, "kill\n")
      assert_receive {^port, {:exit_status, 0}}, 15_000

      {output, 1} =
        Kogen.CompiledFixture.mix_task!(
          root,
          ["kogen.audit", "--confirm", "complete"],
          Map.to_list(env)
        )

      assert output =~ "not_ready"
      {:ok, replayed} = Report.read(root, "complete", current.revision)
      auditor = replayed["layers"]["auditor"]
      assert auditor["status"] == "unavailable"
      assert auditor["reason"] =~ "completion missing"
      assert auditor["attempt_id"] == grant["attempt_id"]
      assert auditor["effects"] == "unknown"
      assert auditor["elapsed_ms"] == nil
      assert auditor["budget_state"]["normal_count"] == 2
      assert auditor["budget_state"]["confirmation_grant"] == "used"
      assert File.read!(counter) == "launch\n"
      assert File.read!(grant_path) |> Jason.decode!() == grant
      refute File.exists?(grant_path <> ".completion")
    after
      if Port.info(port), do: Port.close(port)
    end
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
