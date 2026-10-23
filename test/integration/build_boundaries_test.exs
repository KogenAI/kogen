Code.require_file(Path.expand("../support/integration_helpers.ex", __DIR__))

defmodule Kogen.Integration.BuildBoundariesTest do
  use ExUnit.Case, async: true

  alias Kogen.Integration.{FakeProvider, Helpers}

  @moduletag :integration

  setup_all do
    suite = Helpers.setup_suite!()
    on_exit(fn -> Helpers.cleanup_suite(suite) end)
    {:ok, suite: suite}
  end

  test "REV-5 reviewer repairs are verified and committed without returning to the builder", %{
    suite: suite
  } do
    context =
      fixture!(
        suite,
        Enum.take(build_script(), 2) ++
          [
            {:function, "write_file", %{"path" => "app.txt", "content" => "reviewer repair\n"}},
            {:function, "submit_review", %{"verdict" => "approve", "findings" => []}}
          ]
      )

    {output, status} = Helpers.run_kogen(context, ["intent", "build", "fixture"])
    assert status == 0, output
    assert git_value!(context, ["show", "HEAD:app.txt"]) == "reviewer repair"
    assert result(context)["passes"] == 2
    assert result(context)["reviews"] == 1

    assert length(FakeProvider.provider_requests(context.server)) -
             length(FakeProvider.review_requests(context.server)) == 3
  end

  test "REV-5 final verification failures return to the same reviewer context", %{suite: suite} do
    context =
      fixture!(
        suite,
        Enum.take(build_script(), 2) ++
          [
            {:function, "write_file", %{"path" => "app.txt", "content" => "broken\n"}}
          ] ++
          window_growth() ++
          [
            {:pause, self(), {:function, "read_file", %{"path" => "app.txt"}}}
          ]
      )

    configure_startup!(context, "checks", "! grep -qx broken app.txt", false)
    {card, 5} = Helpers.run_kogen(context, ["intent", "approve", "fixture"])
    [_, hash] = Regex.run(~r/SHA-256: ([0-9a-f]{64})/, card)
    {_, 0} = Helpers.run_kogen(context, ["intent", "approve", "fixture", hash])

    port = Helpers.start_kogen(context, ["intent", "build", "fixture"])
    assert_receive {:provider_paused, provider}, 30_000
    parts = Path.wildcard(Path.join(context.repo, ".kogen/local/runs/*/review-source/*/*.json"))
    assert parts != []
    reads = Enum.map(parts, &{:function, "read_file", %{"path" => &1}})

    actions =
      reads ++
        [
          {:function, "submit_review", %{"verdict" => "approve", "findings" => []}},
          {:function, "write_file", %{"path" => "app.txt", "content" => "reviewer repaired\n"}},
          {:function, "submit_review", %{"verdict" => "approve", "findings" => []}}
        ]

    FakeProvider.append(context.server, actions)

    send(provider, :continue)
    {output, status} = Helpers.await_exit(port, "", 30_000)
    assert status == 0, output
    assert git_value!(context, ["show", "HEAD:app.txt"]) == "reviewer repaired"
    assert result(context)["passes"] == 3
    assert result(context)["reviews"] == 1
    requests = FakeProvider.review_requests(context.server)
    assert length(requests) == 8 + length(parts)
    [reset] = reset_messages(requests)
    assert reset["checks"]["status"] == "stale"

    assert FakeProvider.input_text(Enum.at(requests, 6 + length(parts))) =~ "Final verification"

    assert Enum.any?(
             Enum.at(requests, 6 + length(parts)).json["input"],
             &(&1["type"] == "function_call_output")
           )
  end

  test "preflight missing packages and malformed approval remain structured read observations", %{
    suite: suite
  } do
    context = fixture!(suite, build_script())
    monitor = Path.join(context.root, "fsmonitor")
    marker = Path.join(context.root, "fsmonitor-ran")
    File.write!(monitor, "#!/bin/sh\ntouch #{Kogen.Init.shell_quote(marker)}\n")
    File.chmod!(monitor, 0o700)
    {_, 0} = Helpers.git!(context, ["config", "core.fsmonitor", monitor])
    {out, 0} = Helpers.run_kogen(context, ["intent", "preflight", "fixture", "--json"])
    assert JSON.decode!(out)["data"]["ready"]
    refute File.exists?(marker)
    {out, 1} = Helpers.run_kogen(context, ["intent", "preflight", "missing", "--json"])
    doc = JSON.decode!(out)
    assert doc["error"] == nil
    refute doc["data"]["ready"]

    assert Enum.find(doc["data"]["checks"], &(&1["name"] == "cleanliness"))["status"] ==
             "not_evaluated"

    File.write!(Kogen.Intent.approval_path(context.repo, "fixture"), "{broken")
    {out, 1} = Helpers.run_kogen(context, ["intent", "preflight", "fixture", "--json"])
    doc = JSON.decode!(out)
    assert Enum.any?(doc["data"]["blockers"], &(&1["reason"] == "approval_changed"))
    refute doc["data"]["ready"]
  end

  test "resuming pending reviewer verification keeps repairs with the reviewer", %{suite: suite} do
    context =
      fixture!(
        suite,
        Enum.take(build_script(), 2) ++
          [
            {:function, "write_file", %{"path" => "app.txt", "content" => "reviewer repair\n"}},
            {:function, "submit_review", %{"verdict" => "approve", "findings" => []}}
          ]
      )

    configure_startup!(
      context,
      "checks",
      "if grep -qx 'reviewer repair' app.txt && ! test -f #{context.repo}/.kogen/local/paused; then touch #{context.repo}/.kogen/local/paused; sleep 600; fi",
      false
    )

    port = Helpers.start_kogen(context, ["intent", "build", "fixture"])
    Helpers.wait_for_file!(Path.join(context.repo, ".kogen/local/paused"))
    Helpers.signal!(context, port, "INT")
    {output, 130} = Helpers.await_exit(port, "", 15_000)
    assert output =~ "interrupted"
    {snapshot, 0} = Helpers.run_kogen(context, ["context"])
    data = JSON.decode!(snapshot)["data"]
    assert data["integration_state"] == "ok"
    assert data["active"] == nil
    assert data["last_built"] != nil
    log = Helpers.run_log(context)
    id = Path.basename(Path.dirname(log))
    original = File.read!(Path.join(Path.dirname(log), "result.json"))
    requests = length(FakeProvider.provider_requests(context.server))
    {output, status} = Helpers.run_kogen(context, ["intent", "resume", id])
    assert status == 0, output
    assert output =~ "resuming Build #{id}"
    assert length(FakeProvider.provider_requests(context.server)) == requests
    assert File.read!(Path.join(Path.dirname(log), "result.json")) == original
    assert git_value!(context, ["show", "HEAD:app.txt"]) == "reviewer repair"
  end

  for retry_outcome <- [:green, :setup_red] do
    test "blocked #{retry_outcome} retry provider failure retains fresh evidence and the saved reviewer",
         %{
           suite: suite
         } do
      finding = %{
        "path" => "app.txt",
        "line" => 1,
        "severity" => "blocking",
        "message" => "Original unresolved requirement"
      }

      context =
        fixture!(
          suite,
          Enum.take(build_script(), 2) ++
            [
              {:function, "submit_review", %{"verdict" => "changes", "findings" => [finding]}},
              {:http, 400, %{"error" => %{"message" => "continued request failed"}}},
              {:function, "submit_review", %{"verdict" => "approve", "findings" => []}}
            ]
        )

      trace = Path.join(context.root, "retry-setup-trace")
      red = Path.join(context.root, "retry-setup-red")
      quote = &Kogen.Init.shell_quote/1

      configure_startup!(
        context,
        "setup",
        "echo setup >> #{quote.(trace)}; if test -f #{quote.(red)}; then echo retry-setup-failure; exit 23; fi",
        false
      )

      {output, 1} = Helpers.run_kogen(context, ["intent", "build", "fixture"])
      assert output =~ "review_blocked"
      original_dir = Path.dirname(Helpers.run_log(context))
      original = File.read!(Path.join(original_dir, "checkpoint.json"))

      File.write!(trace, "")
      if unquote(retry_outcome) == :setup_red, do: File.write!(red, "red")

      {output, status} =
        Helpers.run_kogen(context, ["intent", "resume", Path.basename(original_dir)])

      assert status != 0, output

      [child_dir] =
        Path.wildcard(Path.join(context.repo, ".kogen/local/runs/*")) -- [original_dir]

      child_result = JSON.decode!(File.read!(Path.join(child_dir, "result.json")))
      assert child_result["passes"] == 2
      assert File.read!(trace) == "setup\n"
      assert child_result["unknown_requests"] == 1
      assert "review" in child_result["still_failing"]
      child_checkpoint = File.read!(Path.join(child_dir, "checkpoint.json"))
      assert {:ok, _, saved} = Kogen.Run.decode_checkpoint(child_checkpoint)
      assert saved.continuation.stage == :review

      if unquote(retry_outcome) == :setup_red do
        assert saved.continuation.pass.green == false
        assert saved.continuation.pass.not_run == ["acceptance"]
        assert [%{status: 23}] = saved.continuation.pass.setup
        File.rm!(red)
      else
        assert saved.continuation.pass.green
      end

      {output, status} =
        Helpers.run_kogen(context, ["intent", "resume", Path.basename(child_dir)])

      assert status == 0, output

      [final_dir] =
        Path.wildcard(Path.join(context.repo, ".kogen/local/runs/*")) -- [original_dir, child_dir]

      final_result = JSON.decode!(File.read!(Path.join(final_dir, "result.json")))
      assert final_result["passes"] == if(unquote(retry_outcome) == :green, do: 2, else: 3)

      assert File.read!(trace) ==
               if(unquote(retry_outcome) == :green, do: "setup\n", else: "setup\nsetup\n")

      assert final_result["unknown_requests"] == 1
      assert final_result["usage"]["input"] == child_result["usage"]["input"] + 1
      assert File.read!(Path.join(child_dir, "checkpoint.json")) == child_checkpoint
      assert final_result["reviews"] == 1
      assert File.read!(Path.join(original_dir, "checkpoint.json")) == original
      [initial, failed, continued] = FakeProvider.review_requests(context.server)
      assert failed.json["input"] == continued.json["input"]

      assert Enum.take(continued.json["input"], length(initial.json["input"])) ==
               initial.json["input"]

      assert JSON.encode!(continued.json["input"]) =~ finding["message"]

      if unquote(retry_outcome) == :setup_red do
        feedback = List.last(continued.json["input"])["content"]
        assert feedback =~ "retry-setup-failure"
        assert feedback =~ "exit status 23"
        assert feedback =~ "not run because an earlier item failed: acceptance"
      end
    end
  end

  test "pre-clean checkpoints cannot authorize resume", %{suite: suite} do
    context = fixture!(suite, Enum.take(build_script(), 2))
    {_, status} = Helpers.run_kogen(context, ["intent", "build", "fixture"])
    assert status != 0
    run_dir = context |> Helpers.run_log() |> Path.dirname()
    path = Path.join(run_dir, "checkpoint.json")
    doc = JSON.decode!(File.read!(path))
    File.write!(path, JSON.encode!(Map.put(doc, "version", 1)))
    before = state(context)
    requests = length(FakeProvider.provider_requests(context.server))
    {output, status} = Helpers.run_kogen(context, ["intent", "resume", Path.basename(run_dir)])
    assert status == 1, output
    assert output =~ "incompatible checkpoint version 1"
    assert state(context) == before
    assert length(FakeProvider.provider_requests(context.server)) == requests
  end

  for stage <- ["setup", "checks"] do
    test "clean #{stage} input mutations cannot certify the workspace", %{suite: suite} do
      context =
        fixture!(suite, [
          {:function, "write_file", %{"path" => "app.txt", "content" => "candidate\n"}},
          {:function, "finish", %{"summary" => "done"}},
          {:function, "shell", %{"command" => "touch .kogen/local/repair-waiting; sleep 600"}}
        ])

      configure_startup!(
        context,
        unquote(stage),
        "if grep -qx candidate app.txt; then printf 'mutated\\n' > app.txt; fi",
        false
      )

      before = state(context)
      port = Helpers.start_kogen(context, ["intent", "build", "fixture"])
      Helpers.wait_for_file!(Path.join(context.repo, ".kogen/local/repair-waiting"))
      Helpers.signal!(context, port, "INT")
      {output, 130} = Helpers.await_exit(port, "", 15_000)
      assert output =~ "interrupted"
      assert state(context) == before
      assert File.read!(Path.join(context.repo, "app.txt")) == "candidate\n"
      assert "verification" in result(context)["still_failing"]

      assert Enum.any?(
               FakeProvider.tool_outputs(context.server),
               &String.contains?(&1, "files changed while checks ran: app.txt")
             )
    end
  end

  test "clean setup failure returns command output without a partial green pass", %{suite: suite} do
    context =
      fixture!(suite, [
        {:function, "write_file", %{"path" => "app.txt", "content" => "candidate\n"}},
        {:function, "finish", %{"summary" => "done"}},
        {:function, "shell", %{"command" => "touch .kogen/local/repair-waiting; sleep 600"}}
      ])

    configure_startup!(
      context,
      "setup",
      "if grep -qx candidate app.txt; then echo clean-setup-failure; exit 17; fi",
      false
    )

    port = Helpers.start_kogen(context, ["intent", "build", "fixture"])
    Helpers.wait_for_file!(Path.join(context.repo, ".kogen/local/repair-waiting"))
    Helpers.signal!(context, port, "INT")
    {_, 130} = Helpers.await_exit(port, "", 15_000)
    assert result(context)["still_failing"] == ["setup-1"]

    assert Enum.any?(FakeProvider.tool_outputs(context.server), fn text ->
             text =~ "exit status 17" and text =~ "clean-setup-failure"
           end)
  end

  test "workspace drift during clean checks cannot certify a pass", %{suite: suite} do
    context =
      fixture!(suite, [
        {:function, "write_file", %{"path" => "app.txt", "content" => "candidate\n"}},
        {:function, "finish", %{"summary" => "done"}},
        {:function, "shell", %{"command" => "touch .kogen/local/repair-waiting; sleep 600"}}
      ])

    configure_startup!(
      context,
      "checks",
      "if grep -qx candidate app.txt; then printf 'drift\\n' > #{context.repo}/app.txt; fi",
      false
    )

    before = state(context)
    port = Helpers.start_kogen(context, ["intent", "build", "fixture"])
    Helpers.wait_for_file!(Path.join(context.repo, ".kogen/local/repair-waiting"))
    Helpers.signal!(context, port, "INT")
    {_, 130} = Helpers.await_exit(port, "", 15_000)
    assert state(context) == before
    assert File.read!(Path.join(context.repo, "app.txt")) == "drift\n"
    assert "verification" in result(context)["still_failing"]
  end

  test "resume refuses damaged index custody, configuration and required saved state before effects",
       %{
         suite: suite
       } do
    context = fixture!(suite, Enum.take(build_script(), 2))
    {output, status} = Helpers.run_kogen(context, ["intent", "build", "fixture"])
    assert status != 0, output
    run_dir = context |> Helpers.run_log() |> Path.dirname()
    id = Path.basename(run_dir)
    checkpoint = Path.join(run_dir, "checkpoint.json")
    index_backup = Path.join(run_dir, "index-at-start")
    config = Path.join(context.repo, ".kogen/project.yaml")
    saved = Map.new([checkpoint, index_backup, config], &{&1, File.read!(&1)})
    doc = JSON.decode!(saved[checkpoint])
    b = :erlang.binary_to_term(Base.decode64!(doc["state"]))
    broken = Map.put(doc, "state", Base.encode64(:erlang.term_to_binary(Map.delete(b, :phase))))
    custody = fn -> {git_value!(context, ["rev-parse", "HEAD"]), File.read!(b.git_index)} end

    for {path, bytes, fact} <- [
          {index_backup, "damaged original index", "index"},
          {config, "version: [invalid", ".kogen/project.yaml"},
          {checkpoint, JSON.encode!(broken), "checkpoint"}
        ] do
      File.write!(path, bytes)
      before = custody.()
      candidate = File.read!(Path.join(context.repo, "app.txt"))
      approval = File.read!(Path.join(context.repo, ".kogen/local/approvals/fixture.json"))
      evidence = Map.new(File.ls!(run_dir), &{&1, File.read!(Path.join(run_dir, &1))})
      runs = File.ls!(Path.dirname(run_dir))
      requests = length(FakeProvider.provider_requests(context.server))
      {output, status} = Helpers.run_kogen(context, ["intent", "resume", id])
      assert status == 1, output
      assert output =~ "candidate/resume_refused"
      assert output =~ fact
      assert custody.() == before
      assert File.read!(Path.join(context.repo, "app.txt")) == candidate

      assert File.read!(Path.join(context.repo, ".kogen/local/approvals/fixture.json")) ==
               approval

      assert Map.new(File.ls!(run_dir), &{&1, File.read!(Path.join(run_dir, &1))}) == evidence
      assert File.ls!(Path.dirname(run_dir)) == runs
      assert length(FakeProvider.provider_requests(context.server)) == requests
      File.write!(path, saved[path])
    end
  end

  test "a core death during resumed commit reports the created commit and cannot commit again", %{
    suite: suite
  } do
    context =
      fixture!(
        suite,
        Enum.take(build_script(), 2) ++
          [
            {:http, 400, %{"error" => %{"code" => "invalid_request_error", "message" => "stop"}}},
            List.last(build_script())
          ]
      )

    {output, status} = Helpers.run_kogen(context, ["intent", "build", "fixture"])
    assert status != 0, output
    run_dir = context |> Helpers.run_log() |> Path.dirname()
    id = Path.basename(run_dir)
    start = git_value!(context, ["rev-parse", "HEAD"])
    core = Path.join(suite.prefix, "lib/kogen/lib/release/bin/kogen")
    real = core <> ".resume-real"
    pid_file = Path.join(context.root, "core-pid")
    quote = &Kogen.Init.shell_quote/1
    File.rename!(core, real)

    try do
      File.write!(
        core,
        "#!/bin/sh\nprintf '%s\\n' \"$$\" > #{quote.(pid_file)}\nexport RELEASE_PROG=kogen\nexec #{quote.(real)} \"$@\"\n"
      )

      File.chmod!(core, 0o755)
      hooks = context |> Helpers.write_hook!("exit 0\n") |> Path.dirname()
      postcommit = Path.join(hooks, "post-commit")
      File.write!(postcommit, "#!/bin/sh\nkill -KILL \"$(cat #{quote.(pid_file)})\"\n")
      File.chmod!(postcommit, 0o755)
      {output, status} = Helpers.run_kogen(context, ["intent", "resume", id])
      assert status == 70, output
      head = git_value!(context, ["rev-parse", "HEAD"])
      assert head != start
      assert output =~ "after creating commit #{String.slice(head, 0, 8)}"
      assert output =~ "inspect it with git show"
      assert output =~ "run log:"
      assert git_value!(context, ["rev-list", "--count", "#{start}..HEAD"]) == "1"
      [child] = File.ls!(Path.dirname(run_dir)) -- [id]
      requests = length(FakeProvider.provider_requests(context.server))
      {output, status} = Helpers.run_kogen(context, ["intent", "resume", child])
      assert status == 1, output
      assert output =~ "candidate/resume_refused"
      assert output =~ "commit"
      assert git_value!(context, ["rev-parse", "HEAD"]) == head
      assert length(FakeProvider.provider_requests(context.server)) == requests
    after
      File.rm!(core)
      File.rename!(real, core)
    end
  end

  test "REV-6 reviewer shell edits cannot change the approved baseline", %{suite: suite} do
    context =
      fixture!(
        suite,
        Enum.take(build_script(), 2) ++
          [
            {:function, "shell",
             %{"command" => "printf changed > .kogen/intents/fixture/acceptance.feature"}},
            {:function, "submit_review", %{"verdict" => "approve", "findings" => []}}
          ]
      )

    before = state(context)
    {output, status} = Helpers.run_kogen(context, ["intent", "build", "fixture"])
    assert status == 1, output
    assert output =~ "candidate/baseline_changed"
    assert state(context) == before
    assert result(context)["outcome"] == "baseline_changed"
  end

  test "REV-5 interrupted targeted repair reports pending review and changed verification", %{
    suite: suite
  } do
    context =
      fixture!(
        suite,
        Enum.take(build_script(), 2) ++
          [
            {:function, "write_file", %{"path" => "app.txt", "content" => "reviewer repair\n"}},
            {:function, "submit_review", %{"verdict" => "approve", "findings" => []}},
            {:function, "shell", %{"command" => "touch .kogen/local/reviewer-waiting; sleep 600"}}
          ]
      )

    configure_startup!(
      context,
      "checks",
      "if grep -qx 'reviewer repair' app.txt && ! test -f .kogen/local/check-mutated; then printf 'check mutation\\n' > app.txt; touch .kogen/local/check-mutated; fi",
      false
    )

    before = state(context)
    port = Helpers.start_kogen(context, ["intent", "build", "fixture"])
    Helpers.wait_for_file!(Path.join(context.repo, ".kogen/local/reviewer-waiting"))
    Helpers.signal!(context, port, "INT")
    {output, status} = Helpers.await_exit(port, "", 15_000)

    assert status == 130, output
    assert state(context) == before
    assert result(context)["outcome"] == "interrupted"
    assert Enum.sort(result(context)["still_failing"]) == ["review", "verification"]
    assert File.read!(Path.join(context.repo, "app.txt")) == "reviewer repair\n"
    [review_path] = Path.wildcard(Path.join(context.repo, ".kogen/local/runs/*/review-1.json"))
    assert [%{"verdict" => "approve"}] = JSON.decode!(File.read!(review_path))["attempts"]
  end

  test "REV-5 unresolved substantive findings stop rather than start another builder round", %{
    suite: suite
  } do
    context =
      fixture!(
        suite,
        Enum.take(build_script(), 2) ++
          [
            {:function, "submit_review",
             %{
               "verdict" => "changes",
               "findings" => [
                 %{
                   "path" => "app.txt",
                   "line" => 1,
                   "severity" => "blocking",
                   "message" => "Required behavior cannot be repaired within this Intent."
                 }
               ]
             }}
          ]
      )

    before = state(context)
    {output, status} = Helpers.run_kogen(context, ["intent", "build", "fixture"])
    assert status == 1, output
    assert output =~ "candidate/review_blocked"
    assert state(context) == before
    assert result(context)["reviews"] == 1
    assert result(context)["outcome"] == "review_blocked"
  end

  test "reopened reviewer resets preserve the unresolved blocker and cannot authorize commit", %{
    suite: suite
  } do
    finding = %{
      "path" => "app.txt",
      "line" => 1,
      "severity" => "blocking",
      "message" => "Unresolved exact requirement"
    }

    verdict = {:function, "submit_review", %{"verdict" => "changes", "findings" => [finding]}}

    context =
      fixture!(suite, Enum.take(build_script(), 2) ++ [verdict] ++ window_growth() ++ [verdict])

    {output, 1} = Helpers.run_kogen(context, ["intent", "build", "fixture"])
    assert output =~ "review_blocked"
    original_dir = Path.dirname(Helpers.run_log(context))
    original_result = File.read!(Path.join(original_dir, "result.json"))

    before =
      {git_value!(context, ["rev-parse", "HEAD"]),
       File.read!(Path.join(context.repo, ".git/index"))}

    {output, 1} = Helpers.run_kogen(context, ["intent", "resume", Path.basename(original_dir)])
    assert output =~ "review_blocked"

    assert {git_value!(context, ["rev-parse", "HEAD"]),
            File.read!(Path.join(context.repo, ".git/index"))} == before

    assert File.read!(Path.join(original_dir, "result.json")) == original_result
    [reset] = reset_messages(FakeProvider.review_requests(context.server))
    assert reset["owner"] == "review"
    assert reset["findings"] == [finding]

    [child] =
      Path.wildcard(Path.join(context.repo, ".kogen/local/runs/*/checkpoint.json")) --
        [Path.join(original_dir, "checkpoint.json")]

    assert {:ok, _, saved} = Kogen.Run.decode_checkpoint(File.read!(child))
    assert saved.last_review.findings == [finding]
    assert saved.continuation.stage == :review_verify
  end

  test "REV-2 review retains full source without replaying new files twice", %{suite: suite} do
    before = "outside-diff-sentinel\n" <> String.duplicate("context\n", 20) <> "old marker\n"
    after_text = String.replace(before, "old marker", "new marker")

    additions = [
      {:function, "write_file",
       %{"path" => "new-source.txt", "content" => "new-source-sentinel\n"}},
      {:function, "write_file", %{"path" => "existing-context.txt", "content" => after_text}},
      {:function, "shell",
       %{
         "command" =>
           "chmod 755 new-source.txt && printf '\\000\\001\\002' > new-data.bin && mv rename-from.txt rename-to.txt"
       }},
      {:function, "shell",
       %{
         "command" =>
           "git init -q new-submodule && git -C new-submodule -c user.name=Fixture -c user.email=fixture@example.test -c commit.gpgsign=false commit --allow-empty -qm 'Nested fixture'"
       }}
    ]

    context = fixture!(suite, additions ++ build_script())
    File.write!(Path.join(context.repo, "existing-context.txt"), before)
    File.write!(Path.join(context.repo, "rename-from.txt"), "renamed-source-sentinel\n")
    Helpers.git!(context, ["add", "existing-context.txt", "rename-from.txt"])

    Helpers.git!(context, [
      "commit",
      "--only",
      "-qm",
      "Add review context fixture",
      "--",
      "existing-context.txt",
      "rename-from.txt"
    ])

    {output, status} = Helpers.run_kogen(context, ["intent", "build", "fixture"])
    assert status == 0, output
    [review] = FakeProvider.review_requests(context.server)
    material = FakeProvider.input_text(review)
    assert length(:binary.matches(material, "new-source-sentinel")) == 1
    assert material =~ "100755"
    assert material =~ "--- new-data.bin (added; mode 100644) (binary)"
    assert material =~ "deleted file mode 100644"
    assert material =~ "--- rename-from.txt (deleted)"
    assert material =~ "--- rename-to.txt (added; mode 100644)\nrenamed-source-sentinel"

    {submodule_output, 0} = Helpers.git!(context, ["-C", "new-submodule", "rev-parse", "HEAD"])
    submodule_commit = String.trim(submodule_output)

    assert material =~
             "--- new-submodule (added; mode 160000)\nSubproject commit #{submodule_commit}"

    refute material =~ "--- new-submodule (deleted)"
    assert material =~ "-old marker"
    assert material =~ "+new marker"
    assert material =~ after_text
    assert length(:binary.matches(material, "outside-diff-sentinel")) == 1
  end

  for {stage, reason} <- [{"setup", "setup_failed"}, {"checks", "check_failing"}] do
    test "GIT-8 restores the saved index when startup #{stage} fails", %{suite: suite} do
      context = fixture!(suite, [])
      configure_startup!(context, unquote(stage), "exit 12")
      before = state(context)
      arm!(context)

      {output, status} = Helpers.run_kogen(context, ["intent", "build", "fixture"])

      assert status == 3, output
      assert output =~ "environment/" <> unquote(reason)
      refute output =~ "building fixture"
      refute output =~ "failed fixture:"
      refute output =~ "  run log:"
      assert state(context) == before
      assert File.read!(Path.join(context.repo, "app.txt")) == "startup edit\n"
      assert length(FakeProvider.provider_requests(context.server)) == 1
      assert result(context)["outcome"] == unquote(reason)
    end
  end

  test "GIT-8/CLI-7 restores the saved index and reports an interrupted startup", %{suite: suite} do
    context = fixture!(suite, [])
    configure_startup!(context, "setup", "touch .kogen/local/startup-waiting; sleep 600")
    before = state(context)
    arm!(context)
    port = Helpers.start_kogen(context, ["intent", "build", "fixture"])
    Helpers.wait_for_file!(Path.join(context.repo, ".kogen/local/startup-waiting"))
    Helpers.signal!(context, port, "INT")
    {output, status} = Helpers.await_exit(port, "", 15_000)

    assert status == 130, output
    assert output =~ "stopped fixture: interrupted"
    assert state(context) == before
    assert File.read!(Path.join(context.repo, "app.txt")) == "startup edit\n"
    assert length(FakeProvider.provider_requests(context.server)) == 1
    assert result(context)["outcome"] == "interrupted"
  end

  test "CLI-7 undoes a commit interrupted during postcommit validation", %{suite: suite} do
    context = fixture!(suite, build_script())
    before = state(context)
    bin = Path.join(context.root, "bin")
    File.mkdir_p!(bin)
    git = System.find_executable("git")

    # Widen the real postcommit query window without changing Git's output or behavior.
    wrapper = Path.join(bin, "git")

    File.write!(wrapper, """
    #!/bin/sh
    if [ "$1" = cat-file ] && [ "$2" = commit ]; then
      touch .kogen/local/postcommit-waiting
      while [ ! -f .kogen/local/release-query ]; do sleep 0.02; done
    fi
    exec #{Kogen.Init.shell_quote(git)} "$@"
    """)

    File.chmod!(wrapper, 0o755)

    port =
      Helpers.start_kogen(context, ["intent", "build", "fixture"],
        env: [{"PATH", bin <> ":" <> context.env["PATH"]}]
      )

    Helpers.wait_for_file!(Path.join(context.repo, ".kogen/local/postcommit-waiting"))
    Helpers.signal!(context, port, "INT")
    Process.sleep(200)
    File.write!(Path.join(context.repo, ".kogen/local/release-query"), "")
    {output, status} = Helpers.await_exit(port, "", 15_000)

    assert status == 130, output
    assert output =~ "stopped fixture: interrupted"
    refute output =~ "landed fixture"
    assert state(context) == before
    assert File.exists?(Path.join(context.repo, ".kogen/local/approvals/fixture.json"))
    assert File.read!(Path.join(context.repo, "app.txt")) == "verified edit\n"
    assert result(context)["outcome"] == "interrupted"
  end

  test "VER-10/GIT-4 excludes new siblings in another uncommitted Intent folder", %{suite: suite} do
    extra =
      {:function, "write_file",
       %{"path" => ".kogen/intents/staged/new.md", "content" => "new unrelated draft\n"}}

    context = fixture!(suite, [extra | build_script()])
    {output, status} = Helpers.run_kogen(context, ["intent", "build", "fixture"])

    assert status == 0, output
    assert output =~ "landed fixture"
    assert output =~ "kogen: build request gpt-6.1-sol/medium"
    assert output =~ "kogen: build response input="
    assert output =~ "kogen: review request gpt-6.1-sol/high"
    assert output =~ "kogen: review response input="
    assert output =~ "wall_ms="
    committed = git_value!(context, ["diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"])
    assert "app.txt" in String.split(committed, "\n")
    refute committed =~ ".kogen/intents/staged/"

    assert File.read!(Path.join(context.repo, ".kogen/intents/staged/draft.md")) ==
             "caller staged this Intent\n"

    assert File.read!(Path.join(context.repo, ".kogen/intents/staged/new.md")) ==
             "new unrelated draft\n"
  end

  test "AUT-2 stops a preflight hook that changes the approved baseline", %{suite: suite} do
    context = fixture!(suite, build_script())
    before = state(context)
    steps = Path.join(context.repo, "features/steps/integration_steps.js")
    approved = File.read!(steps)

    commit_msg_hook!(
      context,
      "printf '\\n// changed by preflight\\n' >> features/steps/integration_steps.js\ngit add features/steps/integration_steps.js\n"
    )

    {output, status} = Helpers.run_kogen(context, ["intent", "build", "fixture"])

    assert status == 1, output
    assert output =~ "baseline_changed"
    assert state(context) == before
    assert File.read!(steps) != approved
    assert length(FakeProvider.provider_requests(context.server)) == 1
  end

  test "GIT-8 restores the original index when a staging preflight hook rejects", %{suite: suite} do
    context = fixture!(suite, [])
    before = state(context)
    commit_msg_hook!(context, "printf 'hook edit\\n' > app.txt\ngit add app.txt\nexit 12\n")

    {output, status} = Helpers.run_kogen(context, ["intent", "build", "fixture"])

    assert status == 3, output
    assert output =~ "environment/commit_rejected"
    assert state(context) == before
    assert File.read!(Path.join(context.repo, "app.txt")) == "hook edit\n"
    assert length(FakeProvider.provider_requests(context.server)) == 1
  end

  test "GIT-1 rejects a staged rename from outside the allowed Intent paths", %{suite: suite} do
    context = fixture!(suite, build_script())
    Helpers.git!(context, ["mv", "README.md", ".kogen/intents/staged/original-readme.md"])
    before = state(context)

    {output, status} = Helpers.run_kogen(context, ["intent", "build", "fixture"])

    assert status == 5, output
    assert output =~ "environment/dirty_tree"
    assert state(context) == before
    assert length(FakeProvider.provider_requests(context.server)) == 1
  end

  test "CLI-9 records a successful large Unicode startup check and continues", %{suite: suite} do
    context = fixture!(suite, build_script())

    configure_startup!(
      context,
      "checks",
      "node -e \"process.stdout.write('€'.repeat(400000))\"",
      false
    )

    arm!(context)

    {output, status} = Helpers.run_kogen(context, ["intent", "build", "fixture"])

    assert status == 0, output
    assert output =~ "landed fixture"

    events =
      Helpers.run_log(context)
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    event = Enum.find(events, &(&1["event"] == "command_result" and &1["name"] == "startup"))
    assert event["status"] == 0
    assert String.valid?(event["output"])
    assert byte_size(event["output"]) <= 1_048_576
    assert event["output"] =~ "cut in the run log"
  end

  defp commit_msg_hook!(context, command) do
    path = Helpers.write_hook!(context, "exit 0\n") |> Path.dirname() |> Path.join("commit-msg")
    File.write!(path, "#!/bin/sh\n" <> command)
    File.chmod!(path, 0o755)
  end

  defp fixture!(suite, script) do
    context = Helpers.project!(suite, script)
    on_exit(fn -> Helpers.cleanup_case(context) end)
    context
  end

  defp configure_startup!(context, stage, ending, edit \\ true) do
    command =
      "if test -f .kogen/local/arm; then printf 'startup edit\\n' > app.txt; git add app.txt; #{ending}; fi"

    command = if edit, do: command, else: ending
    quoted = "'" <> String.replace(command, "'", "''") <> "'"
    value = if stage == "setup", do: quoted, else: "{name: startup, run: #{quoted}}"
    config = Path.join(context.repo, ".kogen/project.yaml")

    File.write!(
      config,
      String.replace(File.read!(config), "  #{stage}: []", "  #{stage}: [#{value}]")
    )

    Helpers.git!(context, [
      "commit",
      "-q",
      "--only",
      "-m",
      "configure startup probe",
      "--",
      ".kogen/project.yaml"
    ])

    {card, 5} = Helpers.run_kogen(context, ["intent", "approve", "fixture"])
    [_, hash] = Regex.run(~r/SHA-256: ([0-9a-f]{64})/, card)

    {output, status} =
      Helpers.run_kogen(context, ["intent", "approve", "fixture", String.slice(hash, 0, 8)])

    assert status == 0, output
  end

  defp arm!(context), do: File.write!(Path.join(context.repo, ".kogen/local/arm"), "")

  defp state(context) do
    {git_value!(context, ["rev-parse", "HEAD"]), Helpers.index_tree!(context),
     git_value!(context, ["diff", "--cached", "--binary"])}
  end

  defp result(context) do
    [path] = Path.wildcard(Path.join(context.repo, ".kogen/local/runs/*/result.json"))
    path |> File.read!() |> JSON.decode!()
  end

  defp window_growth do
    for _ <- 1..3 do
      {:function, "write_file",
       %{"path" => ".kogen/local/window-padding", "content" => String.duplicate("x", 190_000)}}
    end
  end

  defp reset_messages(requests) do
    for request <- requests,
        item <- request.json["input"],
        is_binary(item["content"]),
        String.starts_with?(item["content"], "Local working-window reset\n"),
        uniq: true do
      item["content"]
      |> String.replace_prefix("Local working-window reset\n", "")
      |> JSON.decode!()
    end
  end

  defp build_script do
    [
      {:function, "write_file", %{"path" => "app.txt", "content" => "verified edit\n"}},
      {:function, "finish", %{"summary" => "The fixture edit is ready."}},
      {:function, "submit_review", %{"verdict" => "approve", "findings" => []}}
    ]
  end

  defp git_value!(context, args) do
    {output, 0} = Helpers.git!(context, args)
    String.trim_trailing(output, "\n")
  end
end
