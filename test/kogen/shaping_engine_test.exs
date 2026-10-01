Code.require_file("../support/shaping_engine_fixture.ex", __DIR__)

defmodule Kogen.ShapingEngineTest do
  @moduledoc """
  The headless Shaping engine end to end in a fixture checkout: the real
  `mix kogen.shape` client, the detached `mix kogen.shape.runner`, the real
  steer hook and Stop hook, and the real `Kogen.ShapingAudit.audit/2` with
  its real `Deterministic` layer. Only the provider
  (`test/support/fake_shaping_controller`) and the auditor/Jev LLM layers
  are fakes.
  """
  use ExUnit.Case, async: true

  alias Kogen.ProcessCustody
  alias Kogen.ShapingAudit.Package
  alias Kogen.ShapingEngineFixture, as: F

  @moduletag :lifecycle
  @moduletag timeout: 600_000

  defp question_turn(extra \\ []) do
    [%{"create_draft" => %{"template" => F.ready_template()}}] ++
      [%{"ask" => %{"number" => 1, "question" => "Which name should the flag have?"}}] ++ extra
  end

  defp start!(root, brief \\ "Add a demo flag.\n", args \\ []) do
    result = F.shape(root, ["--brief", F.input!(root, "brief.md", brief) | args])
    assert result.exit == 0, result.stdout <> result.stderr
    assert [_one_line] = result.lines
    result.json
  end

  test "compiled fixtures preserve Candidate bytes, parent environment and the VM-owned guard" do
    project = Path.expand("../..", __DIR__)
    before = candidate_bytes(project)
    environment = System.get_env()
    guard = System.fetch_env!("KOGEN_TEST_PROCESS_GUARD")
    guard_bytes = File.read!(guard)
    root = F.repo!()
    child_env = F.env(root)
    assert System.get_env() == environment
    refute Path.expand(root) |> String.starts_with?(project <> "/")

    script = """
    import pathlib, sys, time
    guard = pathlib.Path(sys.argv[1])
    original = guard.read_bytes()
    pathlib.Path(sys.argv[2]).write_text('started')
    while not pathlib.Path(sys.argv[3]).exists():
        time.sleep(0.01)
    assert guard.read_bytes() == original
    print('settled')
    """

    children =
      for number <- 1..2 do
        started = Path.join(root, "guard-started-#{number}")
        release = Path.join(root, "guard-release-#{number}")

        task =
          Task.async(fn ->
            System.cmd("python3", ["-B", "-c", script, guard, started, release], env: child_env)
          end)

        wait_file(started)
        {task, release}
      end

    for {task, release} <- children do
      assert File.read!(guard) == guard_bytes
      File.write!(release, "release")
      assert {"settled\n", 0} = Task.await(task, 30_000)
    end

    assert File.read!(guard) == guard_bytes
    assert System.get_env() == environment
    assert candidate_bytes(project) == before
  end

  defp candidate_bytes(project) do
    {paths, 0} = System.cmd("git", ["ls-files", "-z", "-co", "--exclude-standard"], cd: project)

    paths
    |> String.split("\0", trim: true)
    |> Enum.uniq()
    |> Map.new(fn relative ->
      {relative, File.read(Path.join(project, relative))}
    end)
  end

  test "a child VM owns its guard until dependent readers settle, then cleans it" do
    project = Path.expand("../..", __DIR__)
    root = F.repo!()
    marker = Path.join(root, "private-guard-path")
    release = Path.join(root, "guard-owner-release")

    script = """
    Code.require_file(System.fetch_env!("KOGEN_GUARD_TEST_HELPER"))
    File.write!(System.fetch_env!("KOGEN_GUARD_TEST_MARKER"), System.fetch_env!("KOGEN_TEST_PROCESS_GUARD"))
    wait = fn wait ->
      unless File.exists?(System.fetch_env!("KOGEN_GUARD_TEST_RELEASE")) do
        Process.sleep(10)
        wait.(wait)
      end
    end
    wait.(wait)
    """

    code_paths = :code.get_path() |> Enum.flat_map(&["-pa", List.to_string(&1)])

    env = [
      {"KOGEN_ISOLATED_CASE_CHILD", nil},
      {"KOGEN_ISOLATED_BEAM_PREPARE", nil},
      {"KOGEN_GUARD_TEST_HELPER", Path.join(project, "test/test_helper.exs")},
      {"KOGEN_GUARD_TEST_MARKER", marker},
      {"KOGEN_GUARD_TEST_RELEASE", release}
    ]

    owner =
      Task.async(fn ->
        System.cmd("elixir", code_paths ++ ["-e", script], env: env, stderr_to_stdout: true)
      end)

    # Even a failing assertion releases the resource owner before fixture cleanup.
    try do
      wait_file(marker)
      private_guard = File.read!(marker)
      original_guard = System.fetch_env!("KOGEN_TEST_PROCESS_GUARD")
      refute private_guard == original_guard
      bytes = File.read!(original_guard)
      assert File.read!(private_guard) == bytes

      reader =
        "import pathlib,sys; assert pathlib.Path(sys.argv[1]).read_bytes() == pathlib.Path(sys.argv[2]).read_bytes(); print('settled')"

      children =
        for _ <- 1..2 do
          Task.async(fn ->
            System.cmd("python3", ["-B", "-c", reader, private_guard, original_guard],
              stderr_to_stdout: true
            )
          end)
        end

      for child <- children do
        assert File.read!(private_guard) == bytes
        assert {"settled\n", 0} = Task.await(child, 30_000)
      end

      # A premature deletion fails the same dependent reader on a disposable copy.
      prematurely_deleted = Path.join(root, "deleted-guard.dylib")
      File.write!(prematurely_deleted, bytes)
      File.rm!(prematurely_deleted)

      {_error, status} =
        System.cmd("python3", ["-B", "-c", reader, prematurely_deleted, original_guard],
          stderr_to_stdout: true
        )

      refute status == 0
      assert File.read!(private_guard) == bytes
      File.write!(release, "settled")
      {output, status} = Task.await(owner, 30_000)
      assert status == 0, output
      refute File.exists?(private_guard)
      assert File.read!(original_guard) == bytes
    after
      File.write!(release, "settled")
      if Process.alive?(owner.pid), do: Task.await(owner, 30_000)
    end
  end

  test "session custody serializes a stale observation across independent BEAMs" do
    root = F.repo!()
    control = Path.join(root, ".kogen/runtime/custody-race")
    lock_path = Kogen.ProcessCustody.lock_path(control)
    stale_pid = System.pid() |> String.to_integer()
    File.mkdir_p!(Path.dirname(lock_path))

    File.write!(
      lock_path,
      Jason.encode!(%{
        "pid" => stale_pid,
        "started_at" => "gone",
        "build_id" => nil,
        "groups" => []
      })
    )

    classified = Path.join(root, "custody-stale-classified")
    release = Path.join(root, "custody-stale-release")
    acquired = Path.join(root, "custody-first-acquired")
    holder_release = Path.join(root, "custody-holder-release")
    second_started = Path.join(root, "custody-second-started")

    first_script = """
    root = System.fetch_env!("CUSTODY_ROOT")
    control = System.fetch_env!("CUSTODY_CONTROL")
    Process.put({Kogen.ProcessCustody, :before_reclaim}, fn control ->
      {:ok, stale} = Kogen.ProcessCustody.read_lock(control)
      true = Kogen.ProcessCustody.process_start(stale["pid"]) != stale["started_at"]
      File.write!(System.fetch_env!("CUSTODY_CLASSIFIED"), "stale")
      wait = fn wait ->
        unless File.exists?(System.fetch_env!("CUSTODY_RELEASE")) do
          Process.sleep(10)
          wait.(wait)
        end
      end
      wait.(wait)
    end)
    result = Kogen.Shaping.Custody.acquire(control)
    File.write!(Path.join(root, "custody-first-result"), inspect(result))
    File.write!(Path.join(root, "custody-first-pid"), to_string(System.pid()))
    File.write!(System.fetch_env!("CUSTODY_ACQUIRED"), "acquired")
    wait_holder = fn wait_holder ->
      unless File.exists?(System.fetch_env!("CUSTODY_HOLDER_RELEASE")) do
        Process.sleep(10)
        wait_holder.(wait_holder)
      end
    end
    wait_holder.(wait_holder)
    """

    second_script = """
    control = System.fetch_env!("CUSTODY_CONTROL")
    File.write!(System.fetch_env!("CUSTODY_SECOND_STARTED"), "started")
    result = Kogen.Shaping.Custody.acquire(control)
    File.write!(System.fetch_env!("CUSTODY_RESULT"), inspect(result))
    """

    first =
      custody_vm(root, first_script, [
        {"CUSTODY_ROOT", root},
        {"CUSTODY_CONTROL", control},
        {"CUSTODY_CLASSIFIED", classified},
        {"CUSTODY_RELEASE", release},
        {"CUSTODY_ACQUIRED", acquired},
        {"CUSTODY_HOLDER_RELEASE", holder_release}
      ])

    try do
      wait_file(classified)

      second =
        custody_vm(root, second_script, [
          {"CUSTODY_ROOT", root},
          {"CUSTODY_CONTROL", control},
          {"CUSTODY_SECOND_STARTED", second_started},
          {"CUSTODY_RESULT", Path.join(root, "custody-second-result")}
        ])

      wait_file(second_started)
      File.write!(release, "continue")
      wait_file(acquired)
      wait_file(Path.join(root, "custody-second-result"))
      assert {_, 0} = Task.await(second, 30_000)
      assert File.read!(Path.join(root, "custody-first-result")) =~ "reclaimed"
      assert File.read!(Path.join(root, "custody-second-result")) =~ "already present"

      owner = Jason.decode!(File.read!(lock_path))
      assert owner["pid"] == String.to_integer(File.read!(Path.join(root, "custody-first-pid")))
      refute owner["pid"] == stale_pid

      third_started = Path.join(root, "custody-third-started")

      third =
        custody_vm(root, second_script, [
          {"CUSTODY_ROOT", root},
          {"CUSTODY_CONTROL", control},
          {"CUSTODY_SECOND_STARTED", third_started},
          {"CUSTODY_RESULT", Path.join(root, "custody-third-result")}
        ])

      wait_file(third_started)
      assert {_, 0} = Task.await(third, 30_000)
      assert File.read!(Path.join(root, "custody-third-result")) =~ "already present"
      assert File.read!(Path.join(root, "custody-first-result")) =~ "reclaimed"
      File.write!(holder_release, "release")
      assert {_, 0} = Task.await(first, 30_000)
    after
      File.write!(release, "continue")
      File.write!(holder_release, "release")
      if Process.alive?(first.pid), do: Task.await(first, 30_000)
    end
  end

  test "the unguarded custody control reproduces a late stale reclaimer removing a live owner" do
    root = F.repo!()
    control = Path.join(root, ".kogen/runtime/unsafe-custody-race")
    lock_path = Kogen.ProcessCustody.lock_path(control)
    File.mkdir_p!(Path.dirname(lock_path))

    File.write!(
      lock_path,
      Jason.encode!(%{
        "pid" => 999_999_999,
        "started_at" => "gone",
        "build_id" => nil,
        "groups" => []
      })
    )

    classified = Path.join(root, "classified")
    reclaim = Path.join(root, "reclaim")
    finish = Path.join(root, "finish")
    late_result = Path.join(root, "late-result")
    owner_result = Path.join(root, "owner-result")

    script = """
    control = System.fetch_env!("CUSTODY_CONTROL")
    wait = fn wait, path ->
      unless File.exists?(path) do
        Process.sleep(10)
        wait.(wait, path)
      end
    end
    if System.get_env("CUSTODY_PAUSE") == "1" do
      Process.put({Kogen.ProcessCustody, :before_reclaim}, fn _control ->
        File.write!(System.fetch_env!("CUSTODY_CLASSIFIED"), "classified stale")
        wait.(wait, System.fetch_env!("CUSTODY_RECLAIM"))
      end)
    end
    result = Kogen.ProcessCustody.acquire(control)
    File.write!(System.fetch_env!("CUSTODY_RESULT"),
      Jason.encode!(%{"result" => inspect(result), "pid" => String.to_integer(System.pid())}))
    wait.(wait, System.fetch_env!("CUSTODY_FINISH"))
    """

    common = [
      {"CUSTODY_CONTROL", control},
      {"CUSTODY_CLASSIFIED", classified},
      {"CUSTODY_RECLAIM", reclaim},
      {"CUSTODY_FINISH", finish}
    ]

    late =
      custody_vm(
        root,
        script,
        common ++ [{"CUSTODY_PAUSE", "1"}, {"CUSTODY_RESULT", late_result}]
      )

    try do
      wait_file(classified)

      owner =
        custody_vm(
          root,
          script,
          common ++ [{"CUSTODY_PAUSE", "0"}, {"CUSTODY_RESULT", owner_result}]
        )

      try do
        wait_file(owner_result)
        first = Jason.decode!(File.read!(owner_result))
        assert first["result"] =~ "reclaimed"
        assert Jason.decode!(File.read!(lock_path))["pid"] == first["pid"]
        assert F.alive?(first["pid"])
        File.write!(reclaim, "continue stale reclaim")
        wait_file(late_result)
        second = Jason.decode!(File.read!(late_result))
        assert second["result"] =~ "reclaimed"
        assert F.alive?(first["pid"]) and F.alive?(second["pid"])
        assert Jason.decode!(File.read!(lock_path))["pid"] == second["pid"]
        refute second["pid"] == first["pid"]
        File.write!(finish, "finish")
        assert {_, 0} = Task.await(owner, 30_000)
        assert {_, 0} = Task.await(late, 30_000)
      after
        File.write!(finish, "finish")
        if Process.alive?(owner.pid), do: Task.await(owner, 30_000)
      end
    after
      File.write!(reclaim, "continue stale reclaim")
      File.write!(finish, "finish")
      if Process.alive?(late.pid), do: Task.await(late, 30_000)
    end
  end

  defp custody_vm(root, script, extra_env) do
    code_paths = :code.get_path() |> Enum.flat_map(&["-pa", List.to_string(&1)])
    env = F.env(root, extra_env)

    Task.async(fn ->
      System.cmd("elixir", code_paths ++ ["-e", script],
        cd: root,
        env: env,
        stderr_to_stdout: true
      )
    end)
  end

  test "start returns one JSON line at once; the detached runner asks and then costs nothing" do
    root = F.repo!(turns: [question_turn([%{"sleep" => 3}])])
    started = System.monotonic_time(:millisecond)
    json = start!(root)
    elapsed = System.monotonic_time(:millisecond) - started

    assert json["state"] == "running"
    assert json["session"] =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7/
    id = json["session"]

    # The client returned while the fake's turn (3 s of sleep) was still running.
    [launch] = await_launches(root, 1)
    assert F.alive?(launch["pid"]) or elapsed < 3_000

    status = F.await(root, id, &(&1["state"] == "awaiting_answers" and &1["runner"] == false))

    assert [%{"number" => 1, "question" => "Which name should the flag have?"}] =
             status["questions"]

    assert status["slug"] == "flow-demo"

    notes = Enum.filter(F.notifications(root), &(&1["kind"] == "question"))
    assert [%{"body" => body}] = notes
    assert body == "Kogen: 1 question for flow-demo — mix kogen.shape #{id}"

    # Waiting: no runner, no further provider launch.
    Process.sleep(1_500)
    assert length(F.launches(root)) == 1
    assert F.shape(root, [id]).json["runner"] == false
  end

  describe "answers steer the same provider session" do
    test "an answer sent mid-turn reaches the running root session and is recorded once, verbatim" do
      root =
        F.repo!(
          turns: [
            question_turn([
              %{"touch" => ".kogen/asked"},
              %{"wait_for" => %{"path" => ".kogen/answered", "timeout" => 60}},
              %{"hook" => "post_tool_use", "helper" => true},
              %{"hook" => "post_tool_use"},
              %{"record_answers" => true},
              %{"hook" => "post_tool_use"},
              %{"stop" => true}
            ])
          ]
        )

      id = start!(root)["session"]
      wait_file(Path.join(root, ".kogen/asked"))
      answer = "Call it --demo — «ø» 名前.\n"
      sent = F.shape(root, [id, "--brief", F.input!(root, "a1.md", answer), "--request-id", "a1"])
      assert sent.exit == 0
      [input_id] = sent.json["pending_inputs"]
      assert input_id =~ ~r/^in-0002-[0-9a-f]{8}$/
      File.write!(Path.join(root, ".kogen/answered"), "")

      status = F.await(root, id, &(&1["state"] == "ready"))
      questions = File.read!(Path.join(F.draft(root, "flow-demo"), "questions.md"))
      answers = questions |> String.split("## Shaper answers") |> List.last()
      assert length(Regex.scan(~r/\[input #{input_id}\]/, answers)) == 1
      assert answers =~ "[input #{input_id}] " <> String.trim_trailing(answer)

      assert File.read!(Path.join(F.draft(root, "flow-demo"), "evidence/inputs/0002.md")) ==
               answer

      # The helper-flagged call got nothing; the root call got the block once.
      hooks = hook_calls(root)
      assert [%{"helper" => true, "stdout" => ""} | _] = hooks
      delivered = Enum.filter(hooks, &(&1["stdout"] =~ "KOGEN SHAPER ANSWER"))
      assert [only] = delivered
      assert only["helper"] == false
      assert only["stdout"] =~ "[input #{input_id}]"

      # One provider launch: the same process received the answer.
      assert length(F.launches(root)) == 1
      assert status["provider"]["session_id"] == F.session(root, id)["provider_session_id"]
      assert status["presented"]["id"] =~ ~r/^p-1-[0-9a-f]{12}$/
    end

    test "an answer sent after the turn resumes the same provider session" do
      root =
        F.repo!(turns: [question_turn(), [%{"record_answers" => true}, %{"stop" => true}]])

      id = start!(root)["session"]
      F.await(root, id, &(&1["state"] == "awaiting_answers" and &1["runner"] == false))
      provider = F.session(root, id)["provider_session_id"]
      assert is_binary(provider)

      sent = F.shape(root, [id, "--brief", F.input!(root, "a1.md", "Use --demo.\n")])
      assert sent.exit == 0
      F.await(root, id, &(&1["state"] == "ready"))

      [fresh, resume] = F.launches(root)
      assert Enum.take(fresh["argv"], 1) == ["exec"]
      assert Enum.take(resume["argv"], 3) == ["exec", "resume", provider]

      assert resume["stdin"] =~
               "KOGEN SHAPER ANSWER #{F.session(root, id)["nonce"]} [input in-0002-"

      assert F.session(root, id)["provider_session_id"] == provider

      kinds =
        for e <- F.events(root, id),
            e["event"] == "turn_ended",
            do: {e["kind"], e["provider_session_id"]}

      assert kinds == [{"fresh", provider}, {"resume", provider}]
    end
  end

  test "a question written in the turn's last step notifies exactly once; the fake ran outside the client's group" do
    root = F.repo!(turns: [question_turn()])
    id = start!(root)["session"]
    F.await(root, id, &(&1["state"] == "awaiting_answers" and &1["runner"] == false))

    assert [%{"body" => body}] = Enum.filter(F.notifications(root), &(&1["kind"] == "question"))
    assert body =~ "mix kogen.shape #{id}"

    [launch] = F.launches(root)
    refute launch["pgid"] == pgid(System.pid())

    # A later runner with nothing runnable launches nothing and notifies nothing.
    assert runner!(root, id).exit == 0
    assert length(F.launches(root)) == 1
    assert length(F.notifications(root)) == 1
  end

  test "detach.py survives the killed client group; the undetached control dies with it" do
    dir = Path.join(System.tmp_dir!(), "kogen-detach-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    detach = Path.expand("../../priv/kogen/shaping/detach.py", __DIR__)
    pids = Path.join(dir, "pids")

    client = """
    import os, subprocess, sys, time
    os.setpgrp()
    detached = subprocess.run([sys.executable, #{inspect(detach)}, #{inspect(Path.join(dir, "log"))}, "sleep", "30"],
                              capture_output=True, text=True).stdout.strip()
    control = subprocess.Popen(["sleep", "30"]).pid
    with open(#{inspect(pids)} + ".tmp", "w") as handle:
        handle.write("%d %s %d" % (os.getpgrp(), detached, control))
    os.rename(#{inspect(pids)} + ".tmp", #{inspect(pids)})
    time.sleep(60)
    """

    File.write!(Path.join(dir, "client.py"), client)
    System.cmd("sh", ["-c", "python3 #{Path.join(dir, "client.py")} >/dev/null 2>&1 &"])
    wait_file(pids)

    [group, detached, control] =
      pids |> File.read!() |> String.split() |> Enum.map(&String.to_integer/1)

    assert F.alive?(detached) and F.alive?(control)

    System.cmd("kill", ["-KILL", "-#{group}"])
    Process.sleep(300)

    assert F.alive?(detached)
    refute F.alive?(control)
    System.cmd("kill", ["-KILL", to_string(detached)])
  end

  describe "crash matrix: a crash delays an answer, never loses it or records it twice" do
    # Each point kills the runner and the fake's group at a different place;
    # the next `mix kogen.shape.runner` recovers.
    @points %{
      "accepted, never offered" => [
        %{"touch" => ".kogen/answer-wait"},
        %{"wait_for" => %{"path" => ".kogen/answered", "timeout" => 60}},
        %{"touch" => ".kogen/crash-here"},
        %{"sleep_child" => 120}
      ],
      "offered by the steer hook, not recorded" => [
        %{"touch" => ".kogen/answer-wait"},
        %{"wait_for" => %{"path" => ".kogen/answered", "timeout" => 60}},
        %{"hook" => "post_tool_use"},
        %{"touch" => ".kogen/crash-here"},
        %{"sleep_child" => 120}
      ],
      "recorded, before the turn ended" => [
        %{"touch" => ".kogen/answer-wait"},
        %{"wait_for" => %{"path" => ".kogen/answered", "timeout" => 60}},
        %{"hook" => "post_tool_use"},
        %{"record_answers" => true},
        %{"touch" => ".kogen/crash-here"},
        %{"sleep_child" => 120}
      ]
    }

    for {point, steps} <- @points do
      test "crash point: #{point}" do
        steps = unquote(Macro.escape(steps))
        recover = [%{"hook" => "post_tool_use"}, %{"record_answers" => true}, %{"stop" => true}]
        root = F.repo!(turns: [question_turn(steps), recover])
        id = start!(root)["session"]
        wait_file(Path.join(root, ".kogen/answer-wait"))

        sent = F.shape(root, [id, "--brief", F.input!(root, "a.md", "Name it --demo.\n")])
        [input] = sent.json["pending_inputs"]
        File.write!(Path.join(root, ".kogen/answered"), "")
        wait_file(Path.join(root, ".kogen/crash-here"))

        provider = F.session(root, id)["provider_session_id"]
        assert is_binary(provider)
        crash!(root, id)

        recover!(root, id)
        status = F.await_idle(root, id)

        answers = F.draft(root, "flow-demo") |> Path.join("questions.md") |> File.read!()
        assert length(Regex.scan(~r/\[input #{input}\]/, answers)) == 1
        assert answers =~ "[input #{input}] Name it --demo."
        assert status["pending_inputs"] == []

        if unquote(point) == "recorded, before the turn ended" do
          # Nothing is left to deliver: no resume, the dead turn is reported.
          assert [_only] = F.launches(root)
          assert status["state"] == "interrupted"
        else
          assert [_fresh, resume] = F.launches(root)
          assert Enum.take(resume["argv"], 3) == ["exec", "resume", provider]
          assert resume["stdin"] =~ "[input #{input}]"
          assert status["state"] == "ready"
        end

        assert F.session(root, id)["provider_session_id"] == provider
        assert Enum.any?(F.events(root, id), &(&1["event"] == "interrupted"))
        assert Enum.any?(F.notifications(root), &(&1["kind"] == "interrupted"))
      end
    end

    test "crash point: between turns, during the resume that carries the answer" do
      resume_crash = [%{"touch" => ".kogen/crash-here"}, %{"sleep_child" => 120}]
      recover = [%{"record_answers" => true}, %{"stop" => true}]
      root = F.repo!(turns: [question_turn(), resume_crash, recover])
      id = start!(root)["session"]
      F.await(root, id, &(&1["state"] == "awaiting_answers" and &1["runner"] == false))
      provider = F.session(root, id)["provider_session_id"]

      sent = F.shape(root, [id, "--brief", F.input!(root, "a.md", "Use --demo.\n")])
      [input] = sent.json["pending_inputs"]
      wait_file(Path.join(root, ".kogen/crash-here"))
      crash!(root, id)

      recover!(root, id)
      assert F.await_idle(root, id)["state"] == "ready"

      answers = F.draft(root, "flow-demo") |> Path.join("questions.md") |> File.read!()
      assert length(Regex.scan(~r/\[input #{input}\]/, answers)) == 1

      assert [_fresh | resumes] = F.launches(root)
      assert length(resumes) == 2

      for launch <- resumes,
          do: assert(Enum.take(launch["argv"], 3) == ["exec", "resume", provider])

      launch_ids =
        F.session_dir(root, id)
        |> Path.join("inputs/0002.offers.jsonl")
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!(&1)["launch_id"])

      assert length(launch_ids) == 2 and Enum.uniq(launch_ids) == launch_ids
    end
  end

  test "an unanswered question stays open; time passing never makes it an assumption" do
    root = F.repo!(turns: [question_turn()])
    id = start!(root)["session"]
    F.await(root, id, &(&1["state"] == "awaiting_answers" and &1["runner"] == false))
    questions = Path.join(F.draft(root, "flow-demo"), "questions.md")
    before = File.read!(questions)

    Process.sleep(2_000)
    assert runner!(root, id).exit == 0

    assert File.read!(questions) == before
    [_, assumed] = String.split(before, "## Assumed", parts: 2)
    refute assumed |> String.split("\n## ") |> hd() =~ "Which name should the flag have?"
    status = F.shape(root, [id]).json
    assert status["state"] == "awaiting_answers"
    assert [%{"number" => 1}] = status["questions"]
  end

  test "cancel tears the provider group down, keeps every file, does not notify; a message resumes" do
    root =
      F.repo!(
        turns: [
          question_turn([%{"touch" => ".kogen/asked"}, %{"sleep_child" => 120}]),
          [%{"record_answers" => true}, %{"stop" => true}]
        ]
      )

    started = start!(root)
    id = started["session"]

    brief_meta =
      root
      |> F.session_dir(id)
      |> Path.join("inputs/0001.json")
      |> File.read!()
      |> Jason.decode!()

    assert started["receipt"] == %{
             "command" => "start",
             "effect_status" => "received",
             "received_at" => brief_meta["received_at"],
             "request_id" => brief_meta["request_id"]
           }

    assert started["received_input"]["number"] == 1
    assert started["received_input"]["status"] == "received"
    wait_file(Path.join(root, ".kogen/asked"))
    F.await(root, id, fn _ -> Enum.any?(F.notifications(root), &(&1["kind"] == "question")) end)

    answer = F.input!(root, "accepted-before-cancel.md", "Keep this accepted answer.\n")
    received = F.shape(root, [id, "--brief", answer, "--request-id", "before-cancel"])
    assert received.exit == 0
    assert received.json["received_input"]["id"] =~ ~r/^in-0002-/
    assert received.json["received_input"]["number"] == 2
    assert received.json["received_input"]["status"] == "received"

    provider = F.session(root, id)["provider_session_id"]
    [launch] = F.launches(root)
    draft = tree(F.draft(root, "flow-demo"))
    inputs = tree(Path.join(F.session_dir(root, id), "inputs"))
    notes = F.notifications(root)

    cancel_started = System.monotonic_time(:millisecond)
    cancel_args = [id, "--cancel", "--request-id", "cancel-one"]

    {cancel_json, cancel_exit} =
      Kogen.Shaping.main(cancel_args, root: root, env: Map.new(F.driver_env(F.env(root))))

    cancel_elapsed = System.monotonic_time(:millisecond) - cancel_started
    assert cancel_exit == 0
    assert cancel_elapsed < 1_000
    assert cancel_json["receipt"]["command"] == "cancel"
    assert cancel_json["receipt"]["request_id"] == "cancel-one"
    assert cancel_json["receipt"]["effect_status"] == "pending"
    assert cancel_json["cancellation"]["status"] in ["pending", "settled"]

    assert cancel_json["cancellation"]["cutoff"] == %{
             "input_through" => 2,
             "turn_active" => true,
             "turn_through" => 1
           }

    assert {^cancel_json, 0} =
             Kogen.Shaping.main(cancel_args, root: root, env: Map.new(F.driver_env(F.env(root))))

    settled =
      F.await(root, id, fn status ->
        status["runner"] == false and get_in(status, ["cancellation", "status"]) == "settled"
      end)

    assert settled["state"] == "cancelled"

    assert {^cancel_json, 0} =
             Kogen.Shaping.main(cancel_args, root: root, env: Map.new(F.driver_env(F.env(root))))

    Process.sleep(500)
    refute F.alive?(launch["pid"])
    refute group_alive?(launch["pgid"])
    assert F.shape(root, [id]).json["runner"] == false
    assert lock_free?(F.session_dir(root, id))
    assert tree(F.draft(root, "flow-demo")) == draft
    assert tree(Path.join(F.session_dir(root, id), "inputs")) == inputs
    assert F.notifications(root) == notes
    assert F.session(root, id)["state"] == "cancelled"

    assert F.shape(root, [id, "--brief", F.input!(root, "a.md", "Call it --demo.\n")]).exit == 0
    F.await(root, id, &(&1["state"] == "ready"))
    assert [_fresh, resume] = F.launches(root)
    assert Enum.take(resume["argv"], 3) == ["exec", "resume", provider]
    assert F.session(root, id)["provider_session_id"] == provider
  end

  test "delayed detached runners leave cancelled input pending until explicit resume" do
    root = F.repo!(turns: [question_turn(), [%{"record_answers" => true}, %{"stop" => true}]])
    id = start!(root)["session"]
    F.await(root, id, &(&1["state"] == "awaiting_answers" and &1["runner"] == false))
    provider = F.session(root, id)["provider_session_id"]
    dir = F.session_dir(root, id)
    guard = ProcessCustody.lock_path(dir) <> ".guard"
    holder_ready = Path.join(root, "custody-guard-held")
    release_holder = Path.join(root, "custody-guard-release")
    File.mkdir_p!(Path.dirname(guard))

    lock_script = """
    import fcntl, os, sys, time
    handle = open(sys.argv[1], "a+b")
    fcntl.flock(handle, fcntl.LOCK_EX)
    open(sys.argv[2], "w").close()
    while not os.path.exists(sys.argv[3]):
        time.sleep(0.01)
    """

    holder =
      Port.open(
        {:spawn_executable, System.find_executable("python3")},
        [
          :binary,
          :exit_status,
          :use_stdio,
          {:line, 1024},
          args: ["-B", "-c", lock_script, guard, holder_ready, release_holder]
        ]
      )

    try do
      wait_file(holder_ready)

      queued =
        F.shape(root, [id, "--brief", F.input!(root, "before-cancel.md", "Keep this pending.\n")])

      assert queued.exit == 0, queued.stdout <> queued.stderr
      pending_input = queued.json["received_input"]["id"]
      assert queued.json["received_input"]["status"] == "received"

      launch_events =
        Enum.count(F.events(root, id), &(&1["event"] == "runner_launched"))

      assert launch_events == 2

      cancelled = F.shape(root, [id, "--cancel", "--request-id", "cancel-while-delayed"])
      assert cancelled.exit == 0, cancelled.stdout <> cancelled.stderr
      assert cancelled.json["receipt"]["effect_status"] == "pending"
      assert cancelled.json["cancellation"]["status"] == "pending"
      assert Enum.count(F.events(root, id), &(&1["event"] == "runner_launched")) == 3

      File.write!(release_holder, "release")
      assert_receive {^holder, {:exit_status, 0}}, 10_000

      settled =
        F.await(root, id, fn status ->
          status["state"] == "cancelled" and
            get_in(status, ["cancellation", "status"]) == "settled"
        end)

      runner_pids =
        for %{"event" => "runner_launched", "pid" => pid} <- F.events(root, id),
            do: String.to_integer(pid)

      assert length(runner_pids) == 3
      until_gone(fn -> Enum.all?(runner_pids, &(not F.alive?(&1))) end)

      assert settled["pending_inputs"] == [pending_input]
      assert settled["turn_active"] == false
      assert length(F.launches(root)) == 1
      assert Enum.count(F.events(root, id), &(&1["event"] == "turn_started")) == 1
      refute Enum.any?(F.events(root, id), &(&1["event"] == "interrupted"))

      # Represent the terminal-state window where an older turn-active marker
      # is still on disk. A late runner must not classify it as a live crash.
      session_path = Path.join(dir, "session.json")
      cancelled_session = File.read!(session_path)
      stale_turn = Map.put(F.session(root, id), "turn_active", true)
      stale_turn_bytes = Jason.encode!(stale_turn)
      events = F.events(root, id)
      launches = F.launches(root)
      File.write!(session_path, stale_turn_bytes)

      assert runner!(root, id).exit == 0
      assert File.read!(session_path) == stale_turn_bytes
      assert F.events(root, id) == events
      assert F.launches(root) == launches
      File.write!(session_path, cancelled_session)

      resumed =
        F.shape(root, [id, "--brief", F.input!(root, "after-cancel.md", "Use --demo.\n")])

      assert resumed.exit == 0, resumed.stdout <> resumed.stderr
      assert resumed.json["received_input"]["number"] == 3

      assert F.await(root, id, &(&1["state"] == "ready" and &1["runner"] == false))["state"] ==
               "ready"

      [fresh, resume] = F.launches(root)
      assert Enum.take(fresh["argv"], 1) == ["exec"]
      assert Enum.take(resume["argv"], 3) == ["exec", "resume", provider]

      questions = F.draft(root, "flow-demo") |> Path.join("questions.md") |> File.read!()

      for input <- [pending_input, resumed.json["received_input"]["id"]] do
        assert length(Regex.scan(~r/\[input #{input}\]/, questions)) == 1
      end

      assert F.session(root, id)["provider_session_id"] == provider
    after
      File.write!(release_holder, "release")
      if Port.info(holder), do: Port.close(holder)
    end
  end

  test "a delayed runner cannot interrupt an approved session" do
    root =
      F.repo!(
        turns: [[%{"create_draft" => %{"template" => F.ready_template()}}, %{"stop" => true}]]
      )

    id = start!(root)["session"]
    ready = F.await(root, id, &(&1["state"] == "ready" and &1["runner"] == false))

    approved = F.shape(root, [id, "--approve", ready["presented"]["id"]])
    assert approved.exit == 0, approved.stdout <> approved.stderr
    assert F.session(root, id)["state"] == "approved"

    session_path = Path.join(F.session_dir(root, id), "session.json")
    stale_turn_bytes = F.session(root, id) |> Map.put("turn_active", true) |> Jason.encode!()
    File.write!(session_path, stale_turn_bytes)
    events = F.events(root, id)
    launches = F.launches(root)

    assert runner!(root, id).exit == 0
    assert File.read!(session_path) == stale_turn_bytes
    assert F.events(root, id) == events
    assert F.launches(root) == launches
    assert F.shape(root, [id]).json["stored_state"] == "approved"
  end

  test "a changed config blocks a queued turn and keeps its inputs pending" do
    root = F.repo!(turns: [question_turn(), [%{"record_answers" => true}, %{"stop" => true}]])
    id = start!(root)["session"]
    F.await(root, id, &(&1["state"] == "awaiting_answers" and &1["runner"] == false))
    provider = F.session(root, id)["provider_session_id"]
    dir = F.session_dir(root, id)
    config_path = Path.join(root, ".kogen/config.yaml")
    original_config = File.read!(config_path)

    changed_config =
      String.replace(
        original_config,
        "shaping: {model: gpt-5.6-sol, effort: low}",
        "shaping: {model: gpt-5.6-luna, effort: low}",
        global: false
      )

    guard = ProcessCustody.lock_path(dir) <> ".guard"
    holder_ready = Path.join(root, "config-guard-held")
    release_holder = Path.join(root, "config-guard-release")

    lock_script = """
    import fcntl, os, sys, time
    handle = open(sys.argv[1], "a+b")
    fcntl.flock(handle, fcntl.LOCK_EX)
    open(sys.argv[2], "w").close()
    while not os.path.exists(sys.argv[3]):
        time.sleep(0.01)
    """

    holder =
      Port.open(
        {:spawn_executable, System.find_executable("python3")},
        [
          :binary,
          :exit_status,
          :use_stdio,
          {:line, 1024},
          args: ["-B", "-c", lock_script, guard, holder_ready, release_holder]
        ]
      )

    try do
      wait_file(holder_ready)

      queued = F.shape(root, [id, "--brief", F.input!(root, "queued.md", "Keep this answer.\n")])
      assert queued.exit == 0, queued.stdout <> queued.stderr
      pending_input = queued.json["received_input"]["id"]

      File.write!(config_path, changed_config)
      File.write!(release_holder, "release")
      assert_receive {^holder, {:exit_status, 0}}, 10_000

      blocked =
        F.await(root, id, fn status ->
          status["state"] == "blocked" and status["runner"] == false and
            get_in(status, ["error", "code"]) == "configuration_changed"
        end)

      assert blocked["pending_inputs"] == [pending_input]
      assert blocked["turn_active"] == false
      assert length(F.launches(root)) == 1
      assert Enum.count(F.events(root, id), &(&1["event"] == "turn_started")) == 1
      refute File.exists?(Path.join(dir, "inputs/0002.offers.jsonl"))

      File.write!(config_path, original_config)

      resumed =
        F.shape(root, [id, "--brief", F.input!(root, "resume.md", "Use --demo.\n")])

      assert resumed.exit == 0, resumed.stdout <> resumed.stderr
      F.await(root, id, &(&1["state"] == "ready" and &1["runner"] == false))
      [fresh, resume] = F.launches(root)
      assert Enum.take(fresh["argv"], 1) == ["exec"]
      assert Enum.take(resume["argv"], 3) == ["exec", "resume", provider]

      questions = F.draft(root, "flow-demo") |> Path.join("questions.md") |> File.read!()

      for input <- [pending_input, resumed.json["received_input"]["id"]] do
        assert length(Regex.scan(~r/\[input #{input}\]/, questions)) == 1
      end
    after
      File.write!(config_path, original_config)
      File.write!(release_holder, "release")
      if Port.info(holder), do: Port.close(holder)
    end
  end

  test "status derives interrupted after a runner dies during its post-turn audit" do
    root = F.repo!(turns: [[%{"create_draft" => %{"template" => F.ready_template()}}]])
    brief = F.input!(root, "audit-death.md", "Add a demo flag.\n")
    started = F.shape(root, ["--brief", brief], env: [{"FAKE_AUDITOR_SLEEP_SECONDS", "30"}])
    assert started.exit == 0, started.stdout <> started.stderr

    id = started.json["session"]
    dir = F.session_dir(root, id)

    F.await(root, id, fn status ->
      status["runner"] == true and status["turn_active"] == false and
        Enum.any?(F.events(root, id), fn event ->
          event["event"] == "audit_started" and event["trigger"] == "turn_end"
        end)
    end)

    {:ok, %{"pid" => pid, "started_at" => process_started, "build_id" => "kogen-shaping-runner"}} =
      ProcessCustody.read_lock(dir)

    on_exit(fn ->
      case ProcessCustody.read_lock(dir) do
        {:ok,
         %{
           "pid" => ^pid,
           "started_at" => ^process_started,
           "build_id" => "kogen-shaping-runner"
         }} ->
          if ProcessCustody.process_start(pid) == process_started,
            do: System.cmd("kill", ["-KILL", to_string(pid)], stderr_to_stdout: true)

          ProcessCustody.teardown(dir)
          ProcessCustody.release(dir)

        _other ->
          :ok
      end
    end)

    assert ProcessCustody.process_start(pid) == process_started
    assert {_, 0} = System.cmd("kill", ["-KILL", to_string(pid)], stderr_to_stdout: true)

    interrupted = F.await(root, id, &(&1["runner"] == false))
    assert interrupted["stored_state"] == "running"
    assert interrupted["turn_active"] == false
    assert interrupted["state"] == "interrupted"
    assert interrupted["state_source"] == "runner_custody"
    assert interrupted["execution"]["status"] == "interrupted"
    assert interrupted["error"]["code"] == "runner_interrupted"
    assert interrupted["error"]["message"] == interrupted["execution"]["cause"]

    assert not match?({:error, _}, ProcessCustody.teardown(dir))
    assert {:ok, %{"groups" => []}} = ProcessCustody.read_lock(dir)
    assert :ok = ProcessCustody.release(dir)
  end

  describe "durable failures" do
    test "a second runner exits without work while one is live" do
      root =
        F.repo!(turns: [question_turn([%{"touch" => ".kogen/asked"}, %{"sleep_child" => 120}])])

      id = start!(root)["session"]
      wait_file(Path.join(root, ".kogen/asked"))

      assert runner!(root, id).exit == 0
      assert length(F.launches(root)) == 1
      assert F.shape(root, [id, "--cancel"]).exit == 0
    end

    test "missing provider history fails provider_session_unavailable with the Draft untouched" do
      root = F.repo!(turns: [question_turn(), []])
      id = start!(root)["session"]
      F.await(root, id, &(&1["state"] == "awaiting_answers" and &1["runner"] == false))
      provider = F.session(root, id)["provider_session_id"]
      draft = tree(F.draft(root, "flow-demo"))
      F.script!(root, [question_turn(), []], %{"forget_sessions" => true})

      assert F.shape(root, [id, "--brief", F.input!(root, "a.md", "Use --demo.\n")]).exit == 0
      status = F.await(root, id, &(&1["state"] == "failed" and &1["runner"] == false))

      assert status["error"]["code"] == "provider_session_unavailable"
      assert tree(F.draft(root, "flow-demo")) == draft
      assert [_fresh, resume] = F.launches(root)
      assert Enum.take(resume["argv"], 3) == ["exec", "resume", provider]
      assert F.session(root, id)["provider_session_id"] == provider
      assert Enum.any?(F.notifications(root), &(&1["kind"] == "failed"))
    end

    test "a resume answered by another thread id fails provider_session_mismatch" do
      root = F.repo!(turns: [question_turn(), []])
      id = start!(root)["session"]
      F.await(root, id, &(&1["state"] == "awaiting_answers" and &1["runner"] == false))

      F.script!(root, [question_turn(), []], %{
        "resume_thread_id" => "00000000-0000-4000-8000-000000000000"
      })

      assert F.shape(root, [id, "--brief", F.input!(root, "a.md", "Use --demo.\n")]).exit == 0
      status = F.await(root, id, &(&1["state"] == "failed" and &1["runner"] == false))
      assert status["error"]["code"] == "provider_session_mismatch"
    end
  end

  test "caller authority: an external driver's input is interface-attested; a managed caller stores nothing" do
    root = F.repo!(turns: [question_turn()])
    args = ["--interface", "studio", "--request-id", "start-1"]
    id = start!(root, "Add a demo flag.\n", args)["session"]
    F.await(root, id, &(&1["state"] == "awaiting_answers" and &1["runner"] == false))

    meta = F.session_dir(root, id) |> Path.join("inputs/0001.json") |> File.read!()
    decoded = Jason.decode!(meta)
    assert decoded["kind"] == "brief"
    assert decoded["interface"] == "studio"
    assert decoded["request_id"] == "start-1"
    assert is_binary(decoded["received_at"])
    assert decoded["caller"]["authority"] == "interface-attested"
    refute meta =~ "Kogen Fixture"
    refute meta =~ "fixture@example.com"

    # Control: a caller that keeps KOGEN_ROLE is refused and stores nothing.
    managed =
      F.shape(root, [id, "--brief", F.input!(root, "m.md", "Approve it.\n")],
        raw_env: true,
        env: [{"KOGEN_ROLE", "developer"}]
      )

    assert managed.exit == 2
    assert [_one] = managed.lines
    assert managed.json["error"]["code"] == "managed_role"
    refute File.exists?(Path.join(F.session_dir(root, id), "inputs/0002.md"))

    accepted = F.shape(root, [id, "--brief", F.input!(root, "a.md", "Use --demo.\n")])
    assert accepted.exit == 0
    assert File.exists?(Path.join(F.session_dir(root, id), "inputs/0002.md"))
  end

  describe "waiting and Kogen-owned audits" do
    test "Stops while asking pay no LLM layer; one waiting report per awaiting revision" do
      root = F.repo!(turns: [question_turn([%{"stop" => true}])])
      id = start!(root)["session"]
      status = F.await(root, id, &(&1["state"] == "awaiting_answers" and &1["runner"] == false))

      assert Enum.any?(hook_log(root), &(&1["event"] == "Stop"))
      # Only the unchanged question gate asks Jev about the open entry; no
      # Auditor and no Jev contract questions run while asking.
      asking = llm_calls(root)
      assert %{auditor: 0, jev_contract: 0} = asking
      assert status["background_report"] =~ "checkpoint.json"
      assert length(waiting_audits(root, id)) == 1

      assert runner!(root, id).exit == 0
      assert length(waiting_audits(root, id)) == 1
      assert llm_calls(root) == asking
    end

    test "a turn without a Stop gets a turn_end audit and a presentation" do
      root = F.repo!(turns: [[%{"create_draft" => %{"template" => F.ready_template()}}]])
      id = start!(root)["session"]
      status = F.await(root, id, &(&1["state"] == "ready"))

      assert Enum.any?(
               F.events(root, id),
               &(&1["event"] == "audit_started" and &1["trigger"] == "turn_end")
             )

      refute Enum.any?(hook_log(root), &(&1["event"] == "Stop"))
      assert status["presented"]["id"] =~ ~r/^p-1-[0-9a-f]{12}$/
      assert File.exists?(status["presented"]["report_json"])
    end

    test "a full audit made stale by an edit while it ran is re-audited; only a current report is presented" do
      root = F.repo!(turns: [[%{"create_draft" => %{"template" => F.ready_template()}}]])
      intent = Path.join(root, ".kogen/intents/drafts/flow-demo/INTENT.md")
      brief = F.input!(root, "brief.md", "Add a demo flag.\n")

      result = F.shape(root, ["--brief", brief], env: [{"FAKE_SHAPING_AUDITOR_EDIT", intent}])
      assert result.exit == 0, result.stdout <> result.stderr
      id = result.json["session"]
      status = F.await(root, id, &(&1["state"] in ["ready", "blocked"]))

      assert status["state"] == "ready", inspect(status)
      assert File.read!(intent) =~ "Edited while the audit ran."
      assert Enum.any?(F.events(root, id), &(&1["event"] == "report_stale"))

      # The presentation and its report are both of the edited, current bytes.
      {:ok, %{revision: current}} = Package.load(root, ".kogen/intents/drafts/flow-demo")
      presented = status["presented"]
      assert presented["id"] =~ ~r/^p-1-/
      assert presented["revision"] == current
      assert Jason.decode!(File.read!(presented["report_json"]))["revision"] == current

      {:ok, %{revision: copy}} = Package.load(presented["proposal_dir"], ".")
      assert copy == current
    end

    test "status of a ready session no longer reports ready once its Draft, HEAD, route or report changed, and mutates nothing" do
      root = F.repo!(turns: [[%{"create_draft" => %{"template" => F.ready_template()}}]])
      id = start!(root)["session"]
      # With no live runner nothing re-audits, so a stale presentation shows blocked.
      ready = F.await(root, id, &(&1["state"] == "ready" and &1["runner"] == false))
      dir = F.session_dir(root, id)
      intent = Path.join([root, ready["package"], "intent.yaml"])
      original = File.read!(intent)
      session_bytes = File.read!(Path.join(dir, "session.json"))

      changes = [
        {fn -> File.write!(intent, original <> "# a quiet edit\n") end,
         fn -> File.write!(intent, original) end},
        {fn -> git!(root, ["commit", "-q", "--allow-empty", "-m", "move"]) end,
         fn -> git!(root, ["reset", "-q", "--hard", "HEAD~1"]) end},
        {fn ->
           File.rename!(
             ready["presented"]["report_json"],
             ready["presented"]["report_json"] <> ".gone"
           )
         end,
         fn ->
           File.rename!(
             ready["presented"]["report_json"] <> ".gone",
             ready["presented"]["report_json"]
           )
         end},
        # The report is still there, but no longer a full ready one.
        {fn ->
           report = ready["presented"]["report_json"]
           File.cp!(report, report <> ".orig")
           data = report |> File.read!() |> Jason.decode!()
           File.write!(report, Jason.encode!(Map.put(data, "readiness", "not_ready")))
         end,
         fn ->
           File.rename!(
             ready["presented"]["report_json"] <> ".orig",
             ready["presented"]["report_json"]
           )
         end},
        {fn ->
           report = ready["presented"]["report_json"]
           File.cp!(report, report <> ".orig")
           data = report |> File.read!() |> Jason.decode!()
           File.write!(report, Jason.encode!(Map.put(data, "scope", "checkpoint")))
         end,
         fn ->
           File.rename!(
             ready["presented"]["report_json"] <> ".orig",
             ready["presented"]["report_json"]
           )
         end}
      ]

      for {change, undo} <- changes do
        change.()
        stale = Kogen.Shaping.status(root, id)
        assert stale["state"] == "blocked", inspect(stale)
        assert stale["presented"] == nil
        assert stale["error"]["code"] == "presentation_superseded"
        assert File.read!(Path.join(dir, "session.json")) == session_bytes
        undo.()
        assert Kogen.Shaping.status(root, id)["presented"]["id"] == ready["presented"]["id"]
      end

      # A changed route (session.json edited by hand) is stale too.
      File.write!(
        Path.join(dir, "session.json"),
        String.replace(session_bytes, ~s("route": "#{ready["route"]}"), ~s("route": "other"))
      )

      assert Kogen.Shaping.status(root, id)["presented"] == nil
    end

    test "a quiet revision's checkpoint starts mid-turn and its finding reaches the root session" do
      stray = ".kogen/intents/drafts/flow-demo/evidence/inputs/0009.md"
      notice = ".kogen/runtime/shaping/*/notices/au-*.json"

      root =
        F.repo!(
          turns: [
            [
              %{"create_draft" => %{"template" => F.ready_template()}},
              %{"write" => %{"path" => stray, "text" => "an input nobody recorded\n"}},
              %{"wait_for" => %{"path" => notice, "timeout" => 60}},
              %{"hook" => "post_tool_use", "helper" => true},
              %{"hook" => "post_tool_use"}
            ]
          ]
        )

      id = start!(root)["session"]
      F.await_idle(root, id)
      events = F.events(root, id)

      started =
        Enum.find_index(
          events,
          &(&1["event"] == "audit_started" and &1["trigger"] == "checkpoint")
        )

      assert started < Enum.find_index(events, &(&1["event"] == "turn_ended"))

      nonce = F.session(root, id)["nonce"]
      calls = hook_calls(root)
      assert [%{"helper" => true, "stdout" => ""} | _] = calls
      assert [delivered] = Enum.filter(calls, &(&1["stdout"] =~ "KOGEN AUDIT"))
      context = Jason.decode!(delivered["stdout"])["hookSpecificOutput"]["additionalContext"]
      assert context =~ ~r/^KOGEN AUDIT #{nonce} [0-9a-f]{12}\nReport: /
      assert context =~ "input-not-recorded"
    end

    test "control: a checkpoint whose revision changed before delivery is kept stale and not delivered" do
      stray = ".kogen/intents/drafts/flow-demo/evidence/inputs/0009.md"
      checkpoint = ".kogen/runtime/shaping-audits/flow-demo/*/checkpoint.json"
      intent = ".kogen/intents/drafts/flow-demo/INTENT.md"

      root =
        F.repo!(
          turns: [
            [
              %{"create_draft" => %{"template" => F.ready_template()}},
              %{"write" => %{"path" => stray, "text" => "an input nobody recorded\n"}},
              %{"wait_for" => %{"path" => checkpoint, "timeout" => 60}},
              %{"append" => %{"path" => intent, "text" => "\nEdited after the checkpoint.\n"}},
              %{"hook" => "post_tool_use"}
            ]
          ]
        )

      id = start!(root)["session"]
      F.await_idle(root, id)

      refute Enum.any?(hook_calls(root), &(&1["stdout"] =~ "KOGEN AUDIT"))
      [path] = Path.wildcard(Path.join(root, checkpoint))
      report = path |> File.read!() |> Jason.decode!()

      {:ok, %{revision: current}} =
        Package.load(root, ".kogen/intents/drafts/flow-demo")

      refute report["revision"] == current
      assert Path.basename(Path.dirname(path)) == report["revision"]
    end

    test "an accepted input clears the presentation" do
      root =
        F.repo!(
          turns: [
            [%{"create_draft" => %{"template" => F.ready_template()}}, %{"stop" => true}],
            [%{"touch" => ".kogen/resumed"}, %{"sleep_child" => 120}]
          ]
        )

      id = start!(root)["session"]
      ready = F.await(root, id, &(&1["state"] == "ready"))
      assert ready["presented"]

      sent = F.shape(root, [id, "--brief", F.input!(root, "f.md", "One more thing.\n")])
      assert sent.exit == 0
      assert sent.json["presented"] == nil
      refute sent.json["state"] == "ready"
      wait_file(Path.join(root, ".kogen/resumed"))

      refused = F.shape(root, [id, "--approve", ready["presented"]["id"]])
      assert refused.exit == 2
      assert refused.json["error"]["code"] in ["busy", "presentation_superseded"]
      assert F.shape(root, [id, "--cancel"]).exit == 0
    end

    test "a Codex request_user_input call is surfaced, notified and noticed on the next resume" do
      root =
        F.repo!(
          turns: [
            question_turn([%{"request_user_input" => "Which colour should it be?"}]),
            [%{"record_answers" => true}, %{"stop" => true}]
          ]
        )

      id = start!(root)["session"]
      status = F.await(root, id, &(&1["state"] == "awaiting_answers" and &1["runner"] == false))
      assert [%{"text" => text, "turn" => 1}] = status["unrouted_questions"]
      assert text =~ "Which colour should it be?"
      assert Enum.any?(F.notifications(root), &(&1["kind"] == "unrouted"))

      assert F.shape(root, [id, "--brief", F.input!(root, "a.md", "Blue.\n")]).exit == 0
      F.await(root, id, &(&1["state"] == "ready"))
      assert [_fresh, resume] = F.launches(root)

      assert resume["stdin"] =~
               "Your request_user_input call did not reach the human; record it under ## Ask the Shaper."
    end
  end

  defp git!(root, args) do
    {output, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    output
  end

  defp runner!(root, id), do: F.mix(root, ["kogen.shape.runner", id], F.driver_env(F.env(root)))

  defp crash!(root, id) do
    lock =
      F.session_dir(root, id) |> Path.join(".kogen/build.lock") |> File.read!() |> Jason.decode!()

    System.cmd("kill", ["-KILL", to_string(lock["pid"])])

    for launch <- F.launches(root),
        do: System.cmd("kill", ["-KILL", "-#{launch["pgid"]}"], stderr_to_stdout: true)

    # Under a loaded suite a killed process can take a while to disappear;
    # recovery starts only once the runner and every fake group are gone.
    until_gone(fn ->
      not F.alive?(lock["pid"]) and not Enum.any?(F.launches(root), &group_alive?(&1["pgid"]))
    end)
  end

  defp until_gone(fun, tries \\ 300) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("the crashed runner or provider group never exited")
      true -> Process.sleep(100) && until_gone(fun, tries - 1)
    end
  end

  # The recovering runner: a lock still held by a dying process makes it exit
  # without work, so it is retried until it actually ran.
  defp recover!(root, id, tries \\ 50) do
    result = runner!(root, id)

    cond do
      result.exit != 0 -> flunk("runner failed: #{result.stderr}")
      not (result.stderr =~ "another runner holds") -> result
      tries == 0 -> flunk("the session lock was never released: #{result.stderr}")
      true -> Process.sleep(200) && recover!(root, id, tries - 1)
    end
  end

  defp pgid(pid) do
    {out, 0} = System.cmd("ps", ["-o", "pgid=", "-p", to_string(pid)])
    out |> String.trim() |> String.to_integer()
  end

  defp group_alive?(pgid) do
    {_out, status} = System.cmd("kill", ["-0", "-#{pgid}"], stderr_to_stdout: true)
    status == 0
  end

  defp lock_free?(dir) do
    Kogen.Shaping.live_runner(dir) == :none and
      case File.read(Path.join(dir, ".kogen/build.lock")) do
        {:error, :enoent} -> true
        {:ok, text} -> match?({:ok, %{"groups" => []}}, Jason.decode(text))
      end
  end

  defp tree(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
    |> Enum.map(&{Path.relative_to(&1, dir), :crypto.hash(:sha256, File.read!(&1))})
  end

  defp llm_calls(root) do
    auditor = Path.join(root, ".kogen/runtime/fake-auditor/argv")

    requests =
      root
      |> Path.join(".kogen/runtime/fake-jev-audit/request-*.json")
      |> Path.wildcard()
      |> Enum.map(&File.read!/1)

    gate = Enum.count(requests, &(&1 =~ "Who must answer item"))

    %{
      auditor: if(File.exists?(auditor), do: 1, else: 0),
      jev_gate: gate,
      jev_contract: length(requests) - gate
    }
  end

  defp waiting_audits(root, id) do
    for e <- F.events(root, id), e["event"] == "audit_started", e["trigger"] == "waiting", do: e
  end

  defp hook_log(root) do
    case File.read(Path.join(F.log_dir(root), "hooks.jsonl")) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      _ -> []
    end
  end

  defp hook_calls(root) do
    path = Path.join(F.log_dir(root), "hooks.jsonl")

    case File.read(path) do
      {:ok, text} ->
        text
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["event"] == "PostToolUse"))

      _ ->
        []
    end
  end

  defp wait_file(path, tries \\ 1200) do
    cond do
      File.exists?(path) -> :ok
      tries == 0 -> flunk("#{path} never appeared")
      true -> Process.sleep(50) && wait_file(path, tries - 1)
    end
  end

  defp await_launches(root, count, tries \\ 400) do
    launches = F.launches(root)

    cond do
      length(launches) >= count -> launches
      tries == 0 -> flunk("the fake was never launched #{count} times")
      true -> Process.sleep(50) && await_launches(root, count, tries - 1)
    end
  end
end

defmodule Kogen.ShapingEngineDriverEnvTest do
  @moduledoc """
  The external-driver helper strips an inherited `KOGEN_ROLE` and every
  `KOGEN_SHAPING_*` variable. It mutates the process environment, so it runs
  in its own isolated VM.
  """
  use Kogen.IsolatedCase, async: true

  alias Kogen.ShapingEngineFixture, as: F

  @moduletag :lifecycle
  @moduletag timeout: 300_000

  test "the driver helper strips an inherited KOGEN_ROLE; the control keeping it is refused" do
    root = F.repo!(turns: [[]])
    previous = System.get_env("KOGEN_ROLE")
    previous_launch = System.get_env("KOGEN_SHAPING_LAUNCH_ID")
    System.put_env("KOGEN_ROLE", "developer")
    System.put_env("KOGEN_SHAPING_LAUNCH_ID", "inherited")

    try do
      stripped = F.driver_env([])
      assert {"KOGEN_ROLE", nil} in stripped
      assert {"KOGEN_SHAPING_LAUNCH_ID", nil} in stripped

      brief = F.input!(root, "brief.md", "Add a demo flag.\n")
      refused = F.shape(root, ["--brief", brief], raw_env: true)
      assert refused.exit == 2
      assert refused.json["error"]["code"] == "managed_role"
      assert Path.wildcard(Path.join(root, ".kogen/runtime/shaping/*/session.json")) == []

      accepted = F.shape(root, ["--brief", brief])
      assert accepted.exit == 0, accepted.stdout <> accepted.stderr
      assert accepted.json["state"] == "running"
      F.await_idle(root, accepted.json["session"])
    after
      if previous,
        do: System.put_env("KOGEN_ROLE", previous),
        else: System.delete_env("KOGEN_ROLE")

      if previous_launch,
        do: System.put_env("KOGEN_SHAPING_LAUNCH_ID", previous_launch),
        else: System.delete_env("KOGEN_SHAPING_LAUNCH_ID")
    end
  end
end
