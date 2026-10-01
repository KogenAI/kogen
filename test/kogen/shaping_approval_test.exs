Code.require_file("../support/shaping_engine_fixture.ex", __DIR__)

defmodule Kogen.ShapingApprovalTest do
  @moduledoc """
  The approval transaction and caller authority of headless Shaping
  (`explicit-approval-of-presented-revision` and `caller-authority`), in a
  committed fixture checkout with the real `Deterministic` layer and the
  real `ShapingAudit.audit/2`; only the auditor and Jev LLM layers are
  fakes. A ready session is built directly (Draft, session, presentations)
  so the tests do not depend on a provider turn. Commands run through
  `Kogen.Shaping.main/2`, the function `mix kogen.shape` calls.
  """
  use Kogen.IsolatedCase, async: true

  alias Kogen.ProcessCustody
  alias Kogen.Shaping
  alias Kogen.Shaping.{Approval, Draft, Runner, Store}
  alias Kogen.ShapingAudit
  alias Kogen.ShapingAudit.{Package, Report}
  alias Kogen.ShapingEngineFixture, as: F

  @moduletag :lifecycle
  @moduletag timeout: 300_000
  @slug "flow-demo"
  @git_name "Distinctive Git Author Zed"

  # The audit service reads fixture fakes from the process environment, so
  # each test runs in its own isolated VM; the parent only dispatches.
  setup do
    if F.isolated_child?() do
      root = F.repo!()
      git!(root, ["config", "user.name", @git_name])
      git!(root, ["config", "user.email", "zed-distinct@example.invalid"])

      counter = Path.join(root, ".kogen/auditor-launches")
      wrapper = Path.join(root, ".kogen/counting_auditor")

      File.write!(wrapper, """
      #!/bin/sh
      echo launch >> "#{counter}"
      exec "#{Path.join(root, "test/support/shaping_audit/fake_auditor")}" "$@"
      """)

      File.chmod!(wrapper, 0o755)

      env =
        root
        |> F.env()
        |> Map.new()
        |> Map.merge(%{"KOGEN_HARNESS" => wrapper, "FAKE_AUDITOR_MESSAGE" => "empty"})
        |> Map.drop(["KOGEN_ROLE"])

      saved = for {key, _} <- env, do: {key, System.get_env(key)}
      saved_role = System.get_env("KOGEN_ROLE")
      System.delete_env("KOGEN_ROLE")

      Enum.each(env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      on_exit(fn ->
        for {key, value} <- saved,
            do: if(value, do: System.put_env(key, value), else: System.delete_env(key))

        if saved_role, do: System.put_env("KOGEN_ROLE", saved_role)
      end)

      id = Kogen.Intent.mint_uuid7()
      dir = Store.session_dir(root, id)
      session = ready!(root, id, dir)
      {:ok, root: root, id: id, dir: dir, session: session, env: env, counter: counter}
    else
      {:ok, root: nil, id: nil, dir: nil, session: nil, env: nil, counter: nil}
    end
  end

  # --- fixture helpers ------------------------------------------------------

  defp git!(root, args), do: {_, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)

  defp launches(counter) do
    case File.read(counter) do
      {:ok, text} -> length(String.split(text, "\n", trim: true))
      _ -> 0
    end
  end

  defp draft_dir(root), do: F.draft(root, @slug)
  defp approved_dir(root), do: Path.join([root, ".kogen/intents/approved", @slug])

  defp ready!(root, id, dir) do
    File.mkdir_p!(dir)
    {:ok, config} = Kogen.Intent.read_config(Path.join(root, ".kogen/config.yaml"), nil)

    Store.write_session!(dir, %{
      "schema" => Store.schema(),
      "intent_id" => id,
      "route" => config.route,
      "config_fingerprint" => Shaping.config_fingerprint(config),
      "harness" => "codex",
      "model" => config.shaping.model,
      "effort" => config.shaping.effort,
      "provider_session_id" => nil,
      "nonce" => String.duplicate("ab", 16),
      "state" => "running",
      "error" => nil,
      "presented" => nil,
      "presentation_seq" => 0,
      "preexisting_slugs" => [],
      "created_at" => Store.now(),
      "turn_seq" => 1,
      "notified_questions" => [],
      "unrouted_questions" => []
    })

    meta = %{
      "kind" => "brief",
      "interface" => "cli",
      "request_id" => "brief",
      "received_at" => Store.now()
    }

    Store.accept_input!(dir, "Add a demo flag.\n", meta, meta["request_id"])

    draft = draft_dir(root)
    File.mkdir_p!(Path.dirname(draft))
    File.cp_r!(F.ready_template(), draft)
    intent = Path.join(draft, "intent.yaml")

    File.write!(
      intent,
      String.replace(File.read!(intent), ~r/^id: .*$/m, "id: #{id}", global: false)
    )

    present!(root, dir)
    present!(root, dir)
  end

  # Audits the Draft (real Deterministic layer, fake LLM layers) and records
  # a presentation of it, as the runner does on a ready turn.
  defp present!(root, dir) do
    {:ok, session} = Store.read_session(dir)
    {:ok, package} = Draft.locate(root, session["intent_id"])

    {:ok, report, path} =
      ShapingAudit.audit(root, %{
        slug: package.slug,
        route: session["route"],
        auditor: true,
        reuse: true,
        env: System.get_env()
      })

    assert report["readiness"] == "ready", inspect(report["findings"])
    assert report["scope"] == "full"
    assert {:ok, session} = Approval.present!(root, dir, session, package, report, path)
    session
  end

  defp approve(root, id, presentation, extra \\ []) do
    args = [id, "--approve", presentation] ++ extra
    Shaping.main(args, root: root, env: %{})
  end

  defp status(root, id) do
    {json, 0} = Shaping.main([id], root: root, env: %{})
    json
  end

  defp presentation(session), do: session["presented"]["id"]

  defp first_id(session), do: "p-1-" <> binary_part(session["presented"]["revision"], 0, 12)

  defp tree_revision(path) do
    {:ok, %{revision: revision}} = Package.load(path, ".")
    revision
  end

  defp intent_map(root, location \\ :approved) do
    dir = if location == :approved, do: approved_dir(root), else: draft_dir(root)
    {:ok, map} = YamlElixir.read_from_file(Path.join(dir, "intent.yaml"))
    map
  end

  defp no_build?(root, id) do
    not File.exists?(Path.join(root, ".kogen/build.lock")) and
      not File.exists?(Path.join(Store.session_dir(root, id), ".kogen/build.lock")) and
      Path.wildcard(Path.join(root, ".kogen/runtime/scenario-tracking/*")) == []
  end

  defp spawn_holder do
    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, args: ["600"]])
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    started = ProcessCustody.process_start(os_pid)

    # A holder killed by the test may have its pid reused by another suite
    # process before on_exit runs; only the same process is killed.
    on_exit(fn ->
      if ProcessCustody.process_start(os_pid) == started,
        do: System.cmd("kill", ["-KILL", to_string(os_pid)], stderr_to_stdout: true)
    end)

    {os_pid, started}
  end

  defp write_lock!(dir, pid, started) do
    path = ProcessCustody.lock_path(dir)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(%{"pid" => pid, "started_at" => started, "groups" => []}))
  end

  defp dead_lock!(dir) do
    {pid, started} = spawn_holder()
    System.cmd("kill", ["-KILL", to_string(pid)], stderr_to_stdout: true)
    wait_dead(pid)
    write_lock!(dir, pid, started)
  end

  defp wait_dead(pid, tries \\ 100) do
    cond do
      not F.alive?(pid) -> :ok
      tries == 0 -> flunk("holder never died")
      true -> Process.sleep(50) && wait_dead(pid, tries - 1)
    end
  end

  defp write_journal!(dir, session, phase, extra) do
    pid = presentation(session)
    now = Store.now()

    journal =
      Map.merge(
        Approval.read_journal(dir, pid) || %{},
        %{
          "presentation" => pid,
          "slug" => @slug,
          "phase" => phase,
          "history" => [%{"phase" => phase, "at" => now}]
        }
      )
      |> Map.merge(extra)

    Store.write_json!(Path.join([dir, "approvals", pid <> ".json"]), journal)
  end

  # The Draft as a crash in phase `staging` (a snapshot exists) leaves it,
  # optionally already bookkept.
  defp crashed_draft!(root, dir, session, phase) do
    presented = session["presented"]
    snapshot = Path.join(dir, "approvals/#{presented["id"]}.snapshot")
    File.rm_rf!(snapshot)
    File.mkdir_p!(Path.dirname(snapshot))
    File.cp_r!(Path.join(root, presented["proposal_dir"]), snapshot)
    File.mkdir_p!(Path.join(dir, "approvals"))

    if phase != "staging" do
      original = File.read!(Path.join(draft_dir(root), "intent.yaml"))

      approval = %{
        "presentation" => presented["id"],
        "approved_revision" => presented["revision"],
        "approved_against_head" => presented["head"],
        "approved_at" => Store.now(),
        "route" => presented["route"],
        "interface" => "cli",
        "request_id" => "crash",
        "source" => "mix kogen.shape --approve",
        "authority" => "interface-attested"
      }

      File.write!(Path.join(draft_dir(root), "approval.md"), "# Approval\n")

      File.write!(
        Path.join(draft_dir(root), "intent.yaml"),
        Approval.bookkept_intent(original, approval)
      )
    end

    # As `transact` journals it: the presented binding from `staging`, the
    # bookkept revision from `bookkept`.
    binding = %{
      "snapshot" => Path.relative_to(snapshot, dir),
      "presented" => Map.take(presented, ~w(id revision head route inputs_through))
    }

    binding =
      if phase == "staging",
        do: binding,
        else: Map.put(binding, "revision", tree_revision(draft_dir(root)))

    write_journal!(dir, session, phase, binding)
  end

  defp journal(dir, session), do: Approval.read_journal(dir, presentation(session))

  defp await_phase(dir, session, phase, tries \\ 600) do
    cond do
      (journal(dir, session) || %{})["phase"] == phase ->
        :ok

      tries == 0 ->
        flunk("the approval never reached #{phase}: #{inspect(journal(dir, session))}")

      true ->
        Process.sleep(50) && await_phase(dir, session, phase, tries - 1)
    end
  end

  defp change_during_approval!(:head, root, _dir),
    do: git!(root, ["commit", "-q", "--allow-empty", "-m", "move head"])

  defp change_during_approval!(:input, _root, dir) do
    meta = %{
      "kind" => "message",
      "interface" => "cli",
      "request_id" => "late",
      "received_at" => Store.now()
    }

    Store.accept_input!(dir, "Wait, one more thing.\n", meta, meta["request_id"])
  end

  defp change_during_approval!(:draft, root, _dir) do
    questions = Path.join(draft_dir(root), "questions.md")
    File.write!(questions, File.read!(questions) <> "\n2. The label is short.\n")
  end

  defp hash_inputs(dir) do
    for path <- Path.wildcard(Path.join([dir, "inputs", "*"])),
        into: %{},
        do: {Path.basename(path), :crypto.hash(:sha256, File.read!(path))}
  end

  defp await_file(path, task, tries \\ 600) do
    cond do
      File.regular?(path) ->
        path |> File.read!() |> String.trim()

      tries == 0 ->
        flunk(
          "the approval subprocess did not reach its observer: #{inspect(Task.yield(task, 0))}"
        )

      Task.yield(task, 0) != nil ->
        flunk("the approval subprocess exited before its observer")

      true ->
        Process.sleep(50)
        await_file(path, task, tries - 1)
    end
  end

  # --- 1: status of a ready session ------------------------------------------

  test "status of a ready session names an immutable proposal copy of the presented revision",
       ctx do
    %{root: root, id: id, session: session} = ctx
    json = status(root, id)
    presented = json["presented"]

    assert json["state"] == "ready"
    assert presented["id"] == presentation(session)
    assert presented["id"] =~ ~r/^p-2-[0-9a-f]{12}$/
    assert presented["approve_command"] == "mix kogen.shape #{id} --approve #{presented["id"]}"
    assert json["authority"] == "interface-attested"

    proposal = presented["proposal_dir"]
    assert proposal =~ "presentations/2/package"
    assert {:ok, %{revision: revision}} = Package.load(proposal, ".")
    assert revision == presented["revision"]
    assert revision == tree_revision(draft_dir(root))
    assert File.exists?(presented["questions_md"])
    assert File.exists?(presented["scenarios_yaml"])
    assert File.exists?(presented["report_json"])
    assert File.exists?(presented["report_md"])
    assert Jason.decode!(File.read!(presented["report_json"]))["readiness"] == "ready"

    # The copy stays as presented when the Draft moves on.
    File.write!(
      Path.join(draft_dir(root), "questions.md"),
      File.read!(Path.join(draft_dir(root), "questions.md")) <> "\n4. later\n"
    )

    assert tree_revision(proposal) == revision
  end

  # --- 2: approve ------------------------------------------------------------------

  test "--approve of the current presentation bookkeeps, renames and starts no Build", ctx do
    %{root: root, id: id, dir: dir, session: session, counter: counter} = ctx
    presented = session["presented"]
    before_launches = launches(counter)

    assert {json, 0} =
             approve(root, id, presented["id"], ["--interface", "studio", "--request-id", "rid-1"])

    assert json["state"] == "approved"

    assert json["approval"] == %{
             "presentation" => presented["id"],
             "phase" => "done",
             "status" => "approved"
           }

    refute File.exists?(draft_dir(root))
    assert File.dir?(approved_dir(root))
    assert File.exists?(Path.join(approved_dir(root), "approval.md"))

    approval = intent_map(root)["approval"]
    assert approval["presentation"] == presented["id"]
    assert approval["approved_revision"] == presented["revision"]
    assert approval["approved_against_head"] == presented["head"]
    assert approval["route"] == presented["route"]
    assert approval["interface"] == "studio"
    assert approval["request_id"] == "rid-1"
    assert approval["source"] == "mix kogen.shape --approve"
    assert approval["authority"] == "interface-attested"
    assert is_binary(approval["approved_at"])

    assert Store.read_session(dir) |> elem(1) |> Map.fetch!("state") == "approved"
    assert journal(dir, session)["phase"] == "done"
    assert {:error, :enoent} = ProcessCustody.read_lock(dir)
    assert no_build?(root, id)

    # The bookkept revision was checked by a checkpoint audit, not a paid auditor.
    assert launches(counter) == before_launches
    bookkept = journal(dir, session)["revision"]
    assert bookkept == tree_revision(approved_dir(root))
    assert bookkept != presented["revision"]
    assert File.exists?(journal(dir, session)["checkpoint"])

    assert File.exists?(
             Path.join(root, ".kogen/runtime/shaping-audits/#{@slug}/#{bookkept}/checkpoint.json")
           )
  end

  test "the engine-approved package is admitted by Kogen.Intent.read/2", ctx do
    %{root: root, id: id, session: session} = ctx
    assert {%{"state" => "approved"}, 0} = approve(root, id, presentation(session))

    assert {:ok, intent} = Kogen.Intent.read(@slug, Path.join(root, ".kogen/intents/approved"))
    assert intent.id == id
    assert intent.slug == @slug
  end

  # --- 3 & 4: superseded ---------------------------------------------------------------

  test "approving an older presentation is superseded and writes nothing", ctx do
    %{root: root, id: id, dir: dir, session: session} = ctx
    p1 = first_id(session)
    before = File.read!(Path.join(draft_dir(root), "intent.yaml"))

    assert {json, 2} = approve(root, id, p1)
    assert json["error"]["code"] == "presentation_superseded"
    assert json["error"]["message"] =~ presentation(session)
    assert File.read!(Path.join(draft_dir(root), "intent.yaml")) == before
    refute File.exists?(Path.join(draft_dir(root), "approval.md"))
    refute File.exists?(approved_dir(root))
    assert Approval.read_journal(dir, p1) == nil
    assert status(root, id)["presented"]["id"] == presentation(session)
  end

  test "approving when nothing is presented is superseded", ctx do
    %{root: root, id: id, dir: dir, session: session} = ctx
    Store.update_session!(dir, &Map.put(&1, "presented", nil))

    assert {%{"error" => %{"code" => "presentation_superseded"}}, 2} =
             approve(root, id, presentation(session))

    refute File.exists?(approved_dir(root))
    assert {:error, :enoent} = ProcessCustody.read_lock(dir)
  end

  test "an input accepted after the presentation supersedes it", ctx do
    %{root: root, id: id, dir: dir, session: session} = ctx

    meta = %{
      "kind" => "message",
      "interface" => "cli",
      "request_id" => "m1",
      "received_at" => Store.now()
    }

    Store.accept_input!(dir, "Actually, change it.\n", meta, meta["request_id"])

    assert status(root, id)["presented"] == nil

    assert {%{"error" => %{"code" => "presentation_superseded"}}, 2} =
             approve(root, id, presentation(session))

    refute File.exists?(approved_dir(root))
  end

  test "a moved HEAD is re-audited, re-presented under a new id and never approved", ctx do
    %{root: root, id: id, session: session} = ctx
    git!(root, ["commit", "-q", "--allow-empty", "-m", "move head"])

    assert {json, 2} = approve(root, id, presentation(session))
    assert json["error"]["code"] == "presentation_superseded"

    again = status(root, id)
    assert again["state"] == "ready"
    assert again["presented"]["id"] =~ ~r/^p-3-/
    assert again["presented"]["head"] != session["presented"]["head"]
    refute File.exists?(approved_dir(root))
    refute File.exists?(Path.join(draft_dir(root), "approval.md"))

    # The stale id can never approve the newer presentation.
    assert {%{"error" => %{"code" => "presentation_superseded"}}, 2} =
             approve(root, id, presentation(session), ["--request-id", "again"])

    refute File.exists?(approved_dir(root))
  end

  test "a changed route clears the presentation and is never approved", ctx do
    %{root: root, id: id, dir: dir, session: session} = ctx
    Store.update_session!(dir, &Map.put(&1, "route", "other"))

    assert {%{"error" => %{"code" => "presentation_superseded"}}, 2} =
             approve(root, id, presentation(session))

    now = status(root, id)
    assert now["presented"] == nil or now["presented"]["id"] != presentation(session)
    assert now["state"] != "approved"
    refute File.exists?(approved_dir(root))
  end

  test "same-name role changes revoke presentation and approval without paid dispatch", ctx do
    %{root: root, id: id, session: session, counter: counter} = ctx
    config = Path.join(root, ".kogen/config.yaml")
    original = File.read!(config)

    changed =
      String.replace(
        original,
        "auditor: {model: gpt-6.1-sol, effort: high}",
        "auditor: {model: gpt-5.6-luna, effort: low}"
      )

    refute changed == original
    before = launches(counter)
    File.write!(config, changed)

    observed = status(root, id)
    assert observed["state"] == "blocked"
    assert observed["presented"] == nil
    {refusal, 2} = approve(root, id, presentation(session))
    assert refusal["error"]["code"] == "configuration_changed"
    assert File.dir?(draft_dir(root))
    refute File.exists?(approved_dir(root))
    assert launches(counter) == before

    File.write!(config, original)
    assert status(root, id)["state"] == "ready"
    {accepted, 0} = approve(root, id, presentation(session))
    assert accepted["state"] == "approved"
  end

  test "restoring configuration cannot approve an audit from different role settings", ctx do
    %{root: root, id: id, dir: dir, session: session, counter: counter} = ctx
    config_path = Path.join(root, ".kogen/config.yaml")
    original = File.read!(config_path)

    File.write!(
      config_path,
      String.replace(
        original,
        "auditor: {model: gpt-6.1-sol, effort: high}",
        "auditor: {model: gpt-5.6-luna, effort: low}"
      )
    )

    {:ok, package} = Draft.locate(root, id)

    {:ok, report, path} =
      ShapingAudit.audit(root, %{slug: @slug, route: session["route"], auditor: true})

    refute report["config_fingerprint"] == session["config_fingerprint"]
    File.write!(config_path, original)
    before = launches(counter)

    assert {:stale, _} = Approval.present!(root, dir, session, package, report, path)
    assert status(root, id)["state"] == "blocked"
    assert status(root, id)["presented"] == nil

    assert {:stale, ["configuration"]} =
             Report.status(root, @slug, report["revision"], report["head"], report["route"])

    {refusal, 2} = approve(root, id, presentation(session))
    assert refusal["error"]["code"] == "not_ready"
    assert launches(counter) == before
    assert File.dir?(draft_dir(root))
    refute File.exists?(approved_dir(root))
  end

  test "a changed package revision is re-audited, re-presented as p-3 and refused", ctx do
    %{root: root, id: id, session: session} = ctx
    questions = Path.join(draft_dir(root), "questions.md")
    File.write!(questions, File.read!(questions) <> "\n2. The label is short.\n")

    assert {%{"error" => %{"code" => "presentation_superseded"}}, 2} =
             approve(root, id, presentation(session))

    again = status(root, id)
    assert again["presented"]["id"] =~ ~r/^p-3-/
    assert again["presented"]["revision"] != session["presented"]["revision"]
    assert tree_revision(again["presented"]["proposal_dir"]) == again["presented"]["revision"]
    refute File.exists?(approved_dir(root))
  end

  # --- 5: not ready ---------------------------------------------------------------------

  test "an unrecorded accepted input is not_ready", %{root: root, id: id, dir: dir} do
    meta = %{
      "kind" => "message",
      "interface" => "cli",
      "request_id" => "m0",
      "received_at" => Store.now()
    }

    %{"number" => n} =
      Store.accept_input!(dir, "An answer nobody recorded.\n", meta, meta["request_id"])

    # The engine presents nothing while an accepted input is unrecorded.
    {:ok, session} = Store.read_session(dir)
    {:ok, package} = Draft.locate(root, id)

    {:ok, report, path} =
      ShapingAudit.audit(root, %{
        slug: package.slug,
        route: session["route"],
        auditor: true,
        reuse: true,
        env: System.get_env()
      })

    assert {:pending, _session} = Approval.present!(root, dir, session, package, report, path)

    assert Store.read_session(dir) |> elem(1) |> Map.fetch!("presentation_seq") ==
             session["presentation_seq"]

    # Defense in depth: a presentation whose input window covers an
    # unrecorded input (a state the engine no longer produces) still refuses.
    session =
      Store.update_session!(dir, &put_in(&1, ["presented", "inputs_through"], n))

    assert {json, 2} = approve(root, id, presentation(session))
    assert json["error"]["code"] == "not_ready"
    assert json["error"]["message"] =~ "unrecorded input"
    refute File.exists?(approved_dir(root))
    refute File.exists?(Path.join(draft_dir(root), "approval.md"))
  end

  test "an open Ask the Shaper entry is not_ready", %{root: root, id: id, session: session} do
    questions = Path.join(draft_dir(root), "questions.md")

    File.write!(
      questions,
      "## Ask the Shaper\n\n1. Question: Blue or green? Recommendation: blue. Evidence: evidence/probe-color/RESULT.md\n\n" <>
        File.read!(questions)
    )

    assert {json, 2} = approve(root, id, presentation(session))
    assert json["error"]["code"] == "not_ready"
    assert json["error"]["message"] =~ "Ask the Shaper"
    refute File.exists?(approved_dir(root))
    refute File.exists?(Path.join(draft_dir(root), "approval.md"))
  end

  # --- 6: lost response --------------------------------------------------------------------

  test "a repeated --approve replays the recorded outcome and approves once", ctx do
    %{root: root, id: id, dir: dir, session: session} = ctx
    p = presentation(session)
    assert {first, 0} = approve(root, id, p, ["--request-id", "r1"])
    approved_bytes = File.read!(Path.join(approved_dir(root), "intent.yaml"))
    history = journal(dir, session)["history"]

    assert {^first, 0} = approve(root, id, p, ["--request-id", "r1"])
    assert {other, 0} = approve(root, id, p, ["--request-id", "r2", "--interface", "elsewhere"])
    assert other["state"] == "approved"
    assert other["approval"]["presentation"] == p

    assert File.read!(Path.join(approved_dir(root), "intent.yaml")) == approved_bytes
    assert journal(dir, session)["history"] == history
    assert Enum.count(journal(dir, session)["history"], &(&1["phase"] == "done")) == 1
    assert length(Regex.scan(~r/^approval:/m, approved_bytes)) == 1
    assert intent_map(root)["approval"]["interface"] == "cli"
    assert intent_map(root)["approval"]["request_id"] == "r1"
  end

  # --- 7: concurrency -------------------------------------------------------------------------

  test "status during an approval reports it, takes no lock and rolls nothing back", ctx do
    %{root: root, id: id, dir: dir, session: session} = ctx
    crashed_draft!(root, dir, session, "bookkept")
    {pid, started} = spawn_holder()
    write_lock!(dir, pid, started)

    before = %{
      draft: File.read!(Path.join(draft_dir(root), "intent.yaml")),
      lock: File.read!(ProcessCustody.lock_path(dir)),
      journal: File.read!(Path.join([dir, "approvals", presentation(session) <> ".json"])),
      session: File.read!(Path.join(dir, "session.json"))
    }

    json = status(root, id)
    refute json["state"] == "ready"

    assert json["approval"] == %{
             "presentation" => presentation(session),
             "phase" => "bookkept",
             "status" => "approval_in_progress"
           }

    assert File.read!(Path.join(draft_dir(root), "intent.yaml")) == before.draft
    assert File.exists?(Path.join(draft_dir(root), "approval.md"))
    assert File.read!(ProcessCustody.lock_path(dir)) == before.lock

    assert File.read!(Path.join([dir, "approvals", presentation(session) <> ".json"])) ==
             before.journal

    assert File.read!(Path.join(dir, "session.json")) == before.session
  end

  test "a message after ready sampling prevents presentation publication", ctx do
    %{root: root, id: id, dir: dir, session: session} = ctx
    {:ok, package} = Draft.locate(root, id)
    {:ok, report} = Report.read(root, @slug, session["presented"]["revision"])
    parent = self()

    publication =
      Task.async(fn ->
        Process.put({Approval, :observer}, fn
          :before_presentation ->
            send(parent, :sampled_ready)
            receive do: (:publish -> :ok)

          _ ->
            :ok
        end)

        Approval.present!(
          root,
          dir,
          session,
          package,
          report,
          session["presented"]["report_json"]
        )
      end)

    assert_receive :sampled_ready, 10_000
    # Hold custody so the accepted message cannot launch a provider to record
    # it before the publication boundary is observed.
    assert {:ok, _} = ProcessCustody.acquire(dir)
    brief = Path.join(root, "racing-message.md")
    File.write!(brief, "A new decision after ready was sampled.\n")
    assert {_, 0} = Shaping.main([id, "--brief", brief], root: root, env: %{})
    send(publication.pid, :publish)
    assert {:pending, _} = Task.await(publication, 30_000)
    assert {:ok, saved} = Store.read_session(dir)
    assert saved["presented"] == nil
    assert length(status(root, id)["pending_inputs"]) == 1
    refute status(root, id)["state"] == "ready"

    assert {%{"error" => %{"code" => "busy"}}, 2} =
             approve(root, id, presentation(session))

    # A sampled-once implementation would publish the old report while
    # covering the new generation. Status independently suppresses it and
    # leaves every byte alone; approval also refuses the unrecorded input.
    [input] = Store.messages(dir)
    unsafe = put_in(session, ["presented", "inputs_through"], input["number"])
    Store.write_session!(dir, unsafe)
    bytes = File.read!(Path.join(dir, "session.json"))
    assert Store.read_session(dir) |> elem(1) |> Map.fetch!("presented") != nil
    assert status(root, id)["presented"] == nil
    assert status(root, id)["state"] == "running"
    assert File.read!(Path.join(dir, "session.json")) == bytes
    ProcessCustody.release(dir)
    assert status(root, id)["state"] == "blocked"
    assert File.read!(Path.join(dir, "session.json")) == bytes

    assert {%{"error" => %{"code" => "not_ready"}}, 2} =
             approve(root, id, presentation(session))

    Store.write_session!(dir, saved)
  end

  test "a message racing validated commit is busy, then refuses after commitment", ctx do
    %{root: root, id: id, dir: dir, session: session} = ctx
    parent = self()
    before = hash_inputs(dir)
    # The commit acquires a stale pathname, so this also exercises production
    # reclamation before the approval/message interleaving.
    Store.write_json!(Store.commit_lock(dir), %{"pid" => 999_999_999, "started_at" => ""})

    transaction =
      Task.async(fn ->
        Process.put({Approval, :observer}, fn
          :after_validation ->
            send(parent, :validated)
            receive do: (:commit -> :ok)

          _ ->
            :ok
        end)

        approve(root, id, presentation(session))
      end)

    assert_receive :validated, 60_000
    brief = Path.join(root, "commit-message.md")
    File.write!(brief, "An input that must not be stranded.\n")
    args = [id, "--brief", brief, "--request-id", "racing-commit"]
    assert {%{"error" => %{"code" => "busy"}}, 2} = Shaping.main(args, root: root, env: %{})
    assert hash_inputs(dir) == before
    send(transaction.pid, :commit)
    assert {%{"state" => "approved"}, 0} = Task.await(transaction, 60_000)
    assert {%{"error" => %{"code" => "not_ready"}}, 2} = Shaping.main(args, root: root, env: %{})
    assert hash_inputs(dir) == before
  end

  for kind <- [:commit, :request] do
    test "competing stale #{kind} lock reclaimers and a third acquirer remain exclusive", ctx do
      path =
        case unquote(kind) do
          :commit -> Store.commit_lock(ctx.dir)
          :request -> Store.request_lock(Path.join(ctx.dir, "requests/race.json"))
        end

      Store.write_json!(path, %{"pid" => 999_999_999, "started_at" => ""})
      parent = self()

      first =
        Task.async(fn ->
          Process.put({Store, :observer}, fn :stale_lock ->
            send(parent, :observed_stale)
            receive do: (:reclaim -> :ok)
          end)

          Store.with_lock(path, 10_000, fn ->
            send(parent, :first_inside)
            receive do: (:release -> :first)
          end)
        end)

      assert_receive :observed_stale, 10_000

      delayed =
        Task.async(fn ->
          send(parent, :contending)

          Store.with_lock(path, 10_000, fn ->
            send(parent, :second_inside)
            :second
          end)
        end)

      assert_receive :contending, 10_000

      assert {:error, :busy} =
               Store.with_lock(path, 0, fn -> flunk("third holder overlapped") end)

      send(first.pid, :reclaim)
      assert_receive :first_inside, 10_000
      refute_receive :second_inside, 100
      {:ok, live} = Store.read_json(path)
      assert live["pid"] == String.to_integer(System.pid())
      assert {:error, :busy} = Store.with_lock(path, 0, fn -> flunk("live lock was removed") end)
      assert Store.read_json(path) == {:ok, live}
      send(first.pid, :release)
      assert {:ok, :first} = Task.await(first, 10_000)
      assert_receive :second_inside, 10_000
      assert {:ok, :second} = Task.await(delayed, 10_000)
      refute File.exists?(path)
      assert {:ok, :third} = Store.with_lock(path, 0, fn -> :third end)
    end
  end

  test "the former rename-and-restore reclamation exposes a live owner to a third holder", ctx do
    path = Path.join(ctx.dir, "unsafe.lock")
    aside = path <> ".stale"
    Store.write_json!(path, %{"pid" => 999_999_999, "started_at" => ""})
    # Two callers classify the same dead lock; the first takes it and stays
    # inside its callback. The delayed second renames that new live lock.
    {:ok, old} = Store.read_json(path)
    assert old["pid"] == 999_999_999
    File.rm!(path)
    live = %{"pid" => String.to_integer(System.pid()), "token" => "first"}
    Store.write_json!(path, live)
    File.rename!(path, aside)
    assert Store.read_json(aside) == {:ok, live}
    assert {:ok, third} = File.open(path, [:write, :exclusive])
    IO.write(third, Jason.encode!(Map.put(live, "token", "third")))
    File.close(third)
    assert File.ln(aside, path) == {:error, :eexist}
    File.rm!(aside)
    # The unsafe control has two live owners and loses the first's record;
    # the production guard controls above reject this acquisition window.
    assert Store.read_json(path) == {:ok, Map.put(live, "token", "third")}
    refute File.exists?(aside)
  end

  for phase <- [:after_bookkept, :after_rename] do
    test "an exception at #{phase} settles under custody and a public retry converges", ctx do
      %{root: root, id: id, dir: dir, session: session} = ctx
      rid = "approve-exception-#{unquote(phase)}"

      Process.put({Approval, :observer}, fn
        unquote(phase) -> raise "simulated #{unquote(phase)} exception"
        _other -> :ok
      end)

      assert {%{"error" => %{"code" => "internal"}}, 1} =
               approve(root, id, presentation(session), [
                 "--interface",
                 "cli",
                 "--request-id",
                 rid
               ])

      Process.delete({Approval, :observer})

      if unquote(phase) == :after_bookkept do
        assert journal(dir, session)["phase"] == "rolled_back"
        assert File.dir?(draft_dir(root))
        refute File.exists?(Path.join(draft_dir(root), "approval.md"))
      else
        assert journal(dir, session)["phase"] == "done"
        assert File.dir?(approved_dir(root))
      end

      # The incomplete request is retried through the public command. The same
      # RID converges to one approval; changing its arguments conflicts, and a
      # distinct RID observes the already-completed presentation.
      assert {%{"state" => "approved"}, 0} =
               approve(root, id, presentation(session), [
                 "--interface",
                 "cli",
                 "--request-id",
                 rid
               ])

      assert {%{"error" => %{"code" => "request_conflict"}}, 2} =
               approve(root, id, presentation(session), [
                 "--interface",
                 "studio",
                 "--request-id",
                 rid
               ])

      assert {%{"state" => "approved"}, 0} =
               approve(root, id, presentation(session), [
                 "--interface",
                 "cli",
                 "--request-id",
                 rid <> "-new"
               ])

      assert journal(dir, session)["phase"] == "done"
      assert intent_map(root)["approval"]["request_id"] == rid
      assert Enum.count(Store.events(dir), &(&1["event"] == "approved")) == 1

      assert {%{"state" => "approved"}, 0} =
               Shaping.main([id, "--cancel"], root: root, env: %{})

      assert journal(dir, session)["phase"] == "done"
    end
  end

  test "a killed public approval recovers its committed rename gap and preserves later input",
       ctx do
    %{root: root, id: id, dir: dir, session: session} = ctx
    barrier = Path.join(root, ".kogen/rename-gap-barrier")

    child_code = """
    root = System.fetch_env!("KOGEN_CRASH_ROOT")
    id = System.fetch_env!("KOGEN_CRASH_ID")
    presentation = System.fetch_env!("KOGEN_CRASH_PRESENTATION")
    barrier = System.fetch_env!("KOGEN_CRASH_BARRIER")
    Process.put({Kogen.Shaping.Approval, :observer}, fn
      :after_rename ->
        File.write!(barrier, System.pid())
        receive do
          :resume -> :ok
        after
          240_000 -> :ok
        end
      _ -> :ok
    end)
    Kogen.Shaping.main(
      [id, "--approve", presentation, "--request-id", "killed-rename-gap"],
      root: root,
      env: Map.new(System.get_env())
    )
    """

    code_paths =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.filter(&(Path.basename(&1) == "ebin" and File.dir?(&1)))

    args = Enum.flat_map(code_paths, &["-pa", &1]) ++ ["-e", child_code]

    child_env =
      F.env(root, [
        {"KOGEN_CRASH_ROOT", root},
        {"KOGEN_CRASH_ID", id},
        {"KOGEN_CRASH_PRESENTATION", presentation(session)},
        {"KOGEN_CRASH_BARRIER", barrier}
      ])
      |> F.driver_env()

    child =
      Task.async(fn ->
        System.cmd("elixir", args, cd: root, env: child_env, stderr_to_stdout: true)
      end)

    child_pid = String.to_integer(await_file(barrier, child))

    ExUnit.Callbacks.on_exit(fn ->
      if F.alive?(child_pid),
        do: System.cmd("kill", ["-KILL", Integer.to_string(child_pid)], stderr_to_stdout: true)
    end)

    assert journal(dir, session)["phase"] == "audited"
    gap_journal = journal(dir, session)
    assert File.dir?(approved_dir(root))
    assert Store.read_session(dir) |> elem(1) |> Map.fetch!("state") == "ready"
    assert {:ok, %{"pid" => ^child_pid}} = ProcessCustody.read_lock(dir)
    before = hash_inputs(dir)
    brief = Path.join(root, "rename-gap.md")
    File.write!(brief, "An answer after the filesystem committed.\n")

    assert {%{"error" => %{"code" => "busy", "message" => message}}, 2} =
             Shaping.main([id, "--brief", brief], root: root, env: %{})

    assert message =~ "approval"
    assert hash_inputs(dir) == before

    # SIGKILL bypasses transaction settlement and release. The next public
    # approval must reclaim this dead owner's lock before recovery.
    {_, kill_status} = System.cmd("kill", ["-KILL", Integer.to_string(child_pid)])
    assert kill_status == 0
    {_child_output, child_status} = Task.await(child, 30_000)
    assert child_status != 0

    assert {%{"state" => "approved"} = first_outcome, 0} =
             approve(root, id, presentation(session), ["--request-id", "killed-rename-gap"])

    assert {%{"state" => "approved"} = ^first_outcome, 0} =
             approve(root, id, presentation(session), ["--request-id", "rename-gap-retry"])

    assert journal(dir, session)["phase"] == "done"
    assert Store.read_session(dir) |> elem(1) |> Map.fetch!("state") == "approved"
    assert Store.messages(dir) == []

    # The unsafe journal-only decision misses the committed filesystem and
    # accepts an input which remains pending in the already-approved package.
    refute gap_journal["phase"] in ["renamed", "done"]

    Store.write_json!(
      Path.join([dir, "approvals", presentation(session) <> ".json"]),
      gap_journal
    )

    Store.update_session!(dir, &Map.put(&1, "state", "ready"))
    meta = %{"kind" => "message", "interface" => "unsafe-control", "request_id" => "unsafe"}
    Store.accept_input!(dir, File.read!(brief), meta, "unsafe")

    assert {%{"state" => "approved", "approval" => %{"phase" => "done"}}, 0} =
             approve(root, id, presentation(session), ["--request-id", "unsafe-recovery"])

    {:ok, recovered_session} = Store.read_session(dir)
    assert recovered_session["state"] == "approved"
    assert length(Store.messages(dir)) == 1
    assert length(Runner.pending(root, dir, recovered_session)) == 1
    assert journal(dir, session)["phase"] == "done"
    assert journal(dir, session)["outcome"]["state"] == "approved"
  end

  # A change made while the approval is between its bookkeeping and its
  # commit: the test holds the commit lock (as a message storing its input
  # does), lets the approval bookkeep and audit, changes one thing, then
  # releases the lock so the commit makes its final check.
  for change <- [:head, :input, :draft] do
    test "a #{change} change during the approval rolls back and never approves", ctx do
      %{root: root, id: id, dir: dir, session: session} = ctx
      presented = session["presented"]
      parent = self()

      holder =
        Task.async(fn ->
          Store.with_lock(Store.commit_lock(dir), 60_000, fn ->
            send(parent, :locked)
            receive do: (:release -> :ok)
          end)
        end)

      assert_receive :locked, 10_000
      approval = Task.async(fn -> approve(root, id, presentation(session)) end)
      await_phase(dir, session, "bookkept")
      change_during_approval!(unquote(change), root, dir)
      accepted_bytes = hash_inputs(dir)
      send(holder.pid, :release)
      assert {:ok, :ok} = Task.await(holder, 60_000)

      assert {%{"error" => %{"code" => "presentation_superseded"}}, 2} =
               Task.await(approval, 120_000)

      refute File.exists?(approved_dir(root))
      refute File.exists?(Path.join(draft_dir(root), "approval.md"))
      assert journal(dir, session)["phase"] == "rolled_back"
      refute journal(dir, session)["history"] |> Enum.any?(&(&1["phase"] == "audited"))
      assert Store.read_session(dir) |> elem(1) |> Map.fetch!("state") != "approved"

      if unquote(change) != :draft,
        do: assert(tree_revision(draft_dir(root)) == presented["revision"])

      if unquote(change) == :input do
        assert hash_inputs(dir) == accepted_bytes

        assert [%{"request_id" => "late", "text" => "Wait, one more thing.\n"}] =
                 Store.messages(dir)

        {:ok, saved} = Store.read_session(dir)
        assert length(Runner.pending(root, dir, saved)) == 1
      end
    end
  end

  test "a message after the approval committed is refused and stores nothing", ctx do
    %{root: root, id: id, dir: dir, session: session} = ctx
    assert {%{"state" => "approved"}, 0} = approve(root, id, presentation(session))
    before = hash_inputs(dir)
    brief = Path.join(root, "late.md")
    File.write!(brief, "One more thing.\n")

    assert {%{"error" => %{"code" => "not_ready", "message" => message}}, 2} =
             Shaping.main([id, "--brief", brief], root: root, env: System.get_env())

    assert message =~ "approved"
    assert hash_inputs(dir) == before
  end

  test "a crash between the rename and its journal write refuses a message; recovery completes the approval",
       ctx do
    %{root: root, id: id, dir: dir, session: session} = ctx
    crashed_draft!(root, dir, session, "audited")
    File.mkdir_p!(Path.dirname(approved_dir(root)))
    File.rename!(draft_dir(root), approved_dir(root))
    before = hash_inputs(dir)
    brief = Path.join(root, "late.md")
    File.write!(brief, "One more thing.\n")

    assert {%{"error" => %{"code" => "not_ready"}}, 2} =
             Shaping.main([id, "--brief", brief], root: root, env: System.get_env())

    assert hash_inputs(dir) == before

    assert :ok = Approval.recover_approval(dir)
    assert journal(dir, session)["phase"] == "done"
    assert Store.read_session(dir) |> elem(1) |> Map.fetch!("state") == "approved"
  end

  for change <- [:head, :input, :draft] do
    test "recovery of an audited approval after a #{change} change rolls back instead of renaming",
         ctx do
      %{root: root, dir: dir, session: session} = ctx
      crashed_draft!(root, dir, session, "audited")
      change_during_approval!(unquote(change), root, dir)

      assert :ok = Approval.recover_approval(dir)

      refute File.exists?(approved_dir(root))
      assert File.dir?(draft_dir(root))
      refute File.exists?(Path.join(draft_dir(root), "approval.md"))
      assert journal(dir, session)["phase"] == "rolled_back"
      expected_state = if unquote(change) == :input, do: "running", else: "failed"
      assert Store.read_session(dir) |> elem(1) |> Map.fetch!("state") == expected_state
    end
  end

  test "--approve while a live holder holds the lock is busy and changes nothing", ctx do
    %{root: root, id: id, dir: dir, session: session} = ctx
    crashed_draft!(root, dir, session, "bookkept")
    {pid, started} = spawn_holder()
    write_lock!(dir, pid, started)
    lock = File.read!(ProcessCustody.lock_path(dir))
    draft = File.read!(Path.join(draft_dir(root), "intent.yaml"))

    assert {json, 2} = approve(root, id, presentation(session))
    assert json["error"]["code"] == "busy"
    assert File.read!(ProcessCustody.lock_path(dir)) == lock
    assert File.read!(Path.join(draft_dir(root), "intent.yaml")) == draft
    assert journal(dir, session)["phase"] == "bookkept"
    refute File.exists?(approved_dir(root))
    assert F.alive?(pid)
  end

  # --- 8: recovery ------------------------------------------------------------------------------

  test "a live holder's lock is never reclaimed; a dead holder's is, and recovery runs", ctx do
    %{root: root, id: id, dir: dir, session: session} = ctx
    crashed_draft!(root, dir, session, "bookkept")
    dead_lock!(dir)

    assert {json, code} = approve(root, id, presentation(session))
    assert code in [0, 2]
    events = for e <- Store.events(dir), do: e["event"]
    assert "approval_rolled_back" in events
    assert json["session"] == id
  end

  test "recovery of phase renamed completes to done and approved", ctx do
    %{root: root, id: id, dir: dir, session: session} = ctx
    crashed_draft!(root, dir, session, "audited")
    File.mkdir_p!(Path.dirname(approved_dir(root)))
    File.rename!(draft_dir(root), approved_dir(root))

    write_journal!(dir, session, "renamed", %{
      "snapshot" => "approvals/#{presentation(session)}.snapshot"
    })

    dead_lock!(dir)

    assert {json, 0} = approve(root, id, presentation(session))
    assert json["state"] == "approved"
    assert journal(dir, session)["phase"] == "done"
    assert File.exists?(Path.join(approved_dir(root), "approval.md"))
    assert intent_map(root)["approval"]["presentation"] == presentation(session)
  end

  test "recovery of phase renamed with no lock reclaim needed completes directly", ctx do
    %{root: root, dir: dir, session: session} = ctx
    crashed_draft!(root, dir, session, "audited")
    File.mkdir_p!(Path.dirname(approved_dir(root)))
    File.rename!(draft_dir(root), approved_dir(root))
    write_journal!(dir, session, "renamed", %{})

    assert :ok = Approval.recover_approval(dir)
    assert journal(dir, session)["phase"] == "done"
    assert Store.read_session(dir) |> elem(1) |> Map.fetch!("state") == "approved"
  end

  test "public approval retry recovers an audited journal after the custody lock is already free",
       ctx do
    %{root: root, id: id, dir: dir, session: session} = ctx
    crashed_draft!(root, dir, session, "audited")
    refute File.exists?(ProcessCustody.lock_path(dir))
    assert journal(dir, session)["phase"] == "audited"
    assert File.dir?(draft_dir(root))

    assert {%{"state" => "approved"} = result, 0} =
             approve(root, id, presentation(session), ["--request-id", "free-lock-retry"])

    assert result["approval"]["phase"] == "done"
    assert journal(dir, session)["phase"] == "done"
    assert File.dir?(approved_dir(root))
    refute File.exists?(draft_dir(root))
  end

  test "public cancellation rolls back an audited approval that has not renamed", ctx do
    %{root: root, id: id, dir: dir, session: session} = ctx
    crashed_draft!(root, dir, session, "audited")
    accepted_inputs = hash_inputs(dir)
    refute Approval.committed?(dir)
    assert File.dir?(draft_dir(root))
    refute File.exists?(approved_dir(root))

    result = F.shape(root, [id, "--cancel", "--request-id", "cancel-audited-unrenamed"])
    assert result.exit == 0, result.stdout <> result.stderr
    assert result.json["receipt"]["request_id"] == "cancel-audited-unrenamed"
    assert result.json["receipt"]["effect_status"] == "pending"

    settled =
      F.await(root, id, fn status ->
        status["state"] == "cancelled" and
          get_in(status, ["cancellation", "status"]) == "settled"
      end)

    assert get_in(settled, ["cancellation", "settlement", "observed_outcome"]) == "cancelled"
    assert journal(dir, session)["phase"] == "rolled_back"
    assert File.dir?(draft_dir(root))
    refute File.exists?(Path.join(draft_dir(root), "approval.md"))
    refute File.exists?(approved_dir(root))
    assert tree_revision(draft_dir(root)) == session["presented"]["revision"]
    assert hash_inputs(dir) == accepted_inputs
    assert F.launches(root) == []
  end

  test "public cancellation recovers a committed rename without repeating approval", ctx do
    %{root: root, id: id, dir: dir, session: session} = ctx
    crashed_draft!(root, dir, session, "audited")
    File.mkdir_p!(Path.dirname(approved_dir(root)))
    File.rename!(draft_dir(root), approved_dir(root))
    Store.event!(dir, "approved", %{"presentation" => presentation(session)})
    assert Approval.committed?(dir)
    assert Approval.recovery_pending?(dir)

    result = F.shape(root, [id, "--cancel", "--request-id", "cancel-committed-rename"])
    assert result.exit == 0, result.stdout <> result.stderr
    assert result.json["receipt"]["request_id"] == "cancel-committed-rename"

    settled =
      F.await(root, id, fn status ->
        status["state"] == "approved" and status["runner"] == false and
          journal(dir, session)["phase"] == "done"
      end)

    assert get_in(settled, ["cancellation", "settlement", "observed_outcome"]) == "approved"
    assert journal(dir, session)["phase"] == "done"
    assert File.dir?(approved_dir(root))
    refute File.exists?(draft_dir(root))
    assert Enum.count(Store.events(dir), &(&1["event"] == "approved")) == 1
    assert F.launches(root) == []
  end

  test "recovery of phase audited with the Draft present and the target absent renames and completes",
       ctx do
    %{root: root, dir: dir, session: session} = ctx
    crashed_draft!(root, dir, session, "audited")
    refute File.exists?(approved_dir(root))

    assert :ok = Approval.recover_approval(dir)
    refute File.exists?(draft_dir(root))
    assert File.exists?(Path.join(approved_dir(root), "approval.md"))
    assert journal(dir, session)["phase"] == "done"
    assert Store.read_session(dir) |> elem(1) |> Map.fetch!("state") == "approved"
  end

  for phase <- ["staging", "bookkept"] do
    test "recovery of phase #{phase} restores the exact snapshot bytes and keeps the presentation",
         ctx do
      %{root: root, id: id, dir: dir, session: session} = ctx
      presented = session["presented"]
      before = File.read!(Path.join(draft_dir(root), "intent.yaml"))
      crashed_draft!(root, dir, session, unquote(phase))

      assert :ok = Approval.recover_approval(dir)

      assert File.read!(Path.join(draft_dir(root), "intent.yaml")) == before
      refute File.exists?(Path.join(draft_dir(root), "approval.md"))
      assert tree_revision(draft_dir(root)) == presented["revision"]
      assert journal(dir, session)["phase"] == "rolled_back"
      assert journal(dir, session)["verified"] == true

      {:ok, stored} = Store.read_session(dir)
      assert stored["state"] == "failed"
      assert stored["error"]["code"] == "approval_rolled_back"
      assert stored["presented"]["id"] == presented["id"]

      # The presentation stays, so the retry works.
      assert {%{"state" => "approved"}, 0} =
               approve(root, id, presented["id"], ["--request-id", "retry"])

      assert File.exists?(Path.join(approved_dir(root), "approval.md"))
    end
  end

  # --- 9: caller authority ----------------------------------------------------------------------------

  test "a managed role is refused and nothing is stored", ctx do
    %{root: root, id: id, dir: dir, session: session} = ctx
    before = File.ls!(dir) |> Enum.sort()

    assert {json, 2} =
             Shaping.main([id, "--approve", presentation(session)],
               root: root,
               env: %{"KOGEN_ROLE" => "developer"}
             )

    assert json["error"]["code"] == "managed_role"
    assert File.ls!(dir) |> Enum.sort() == before
    refute File.exists?(Path.join(dir, "requests"))
    refute File.exists?(Path.join(dir, "approvals"))
    refute File.exists?(approved_dir(root))
    assert File.exists?(draft_dir(root))
  end

  test "an external driver's approval records interface, request id and authority, never Git identity",
       ctx do
    %{root: root, id: id, dir: dir, session: session} = ctx
    p = presentation(session)

    assert {_json, 0} =
             approve(root, id, p, ["--interface", "studio", "--request-id", "studio-req-7"])

    request = dir |> Path.join("requests/studio-req-7.json") |> File.read!() |> Jason.decode!()
    assert request["interface"] == "studio"
    assert request["command"] == "approve"
    assert is_binary(request["received_at"])
    assert request["outcome"]["state"] == "approved"

    approval = intent_map(root)["approval"]
    assert approval["interface"] == "studio"
    assert approval["request_id"] == "studio-req-7"
    assert approval["presentation"] == p
    assert approval["authority"] == "interface-attested"

    markdown = File.read!(Path.join(approved_dir(root), "approval.md"))
    assert markdown =~ "interface-attested"
    assert markdown =~ "studio"
    assert markdown =~ "studio-req-7"
    assert markdown =~ p
    assert markdown =~ "verified no human identity"
    refute markdown =~ ~r/verified human|human verified|approved by [A-Z]/

    {:ok, %{files: files}} = Package.load(approved_dir(root), ".")

    assert System.cmd("git", ["config", "user.name"], cd: root) |> elem(0) |> String.trim() ==
             @git_name

    for text <- [
          markdown,
          inspect(approval),
          files["intent.yaml"],
          File.read!(Path.join(dir, "approvals/#{p}.json"))
        ] do
      refute text =~ @git_name
      refute text =~ "zed-distinct"
    end
  end
end
