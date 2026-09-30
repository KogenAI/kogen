defmodule Kogen.GuardViolationReworkTest do
  @moduledoc """
  Ordinary extra paths are disclosed to the Reviewer with controller-derived
  hunks, while Approved-copy additions resume the same Developer session to
  delete them (at most `@guard_reworks` 2 per attempt, no verification cycle).
  Git policy, protected hook/agent
  configuration, Approved-copy edits and failed turns stay terminal, and
  control's shared Git files are environment events. Real Git fixtures with
  test/support/fake_stray_writer_role.
  """
  use Kogen.IsolatedCase, async: true

  alias Kogen.Build.ReviewPacket
  alias Kogen.CandidateFixture, as: Candidate
  alias Kogen.WorkspaceFixture, as: Fixture

  @slug Fixture.slug()
  @approved ".kogen/intents/approved/#{@slug}"
  @stray_prefix "Candidate changed paths outside Approved guards: "
  @work_header "[Developer notes, turn that ended in guard rework 1]"
  @passed_header "[Developer notes, turn that passed the guard]"
  @cleanup "Removed the listed stray paths."

  setup do
    if Fixture.isolated_child?() do
      control = Fixture.create!()
      on_exit(fn -> File.rm_rf(control) end)
      %{control: control}
    else
      # The parent only dispatches; the pattern keys must still exist.
      %{control: nil}
    end
  end

  describe "stray-file-reworked" do
    test "stray files, a Mix lock directory and an Approved-copy addition are reworked in the same session and the Build is accepted",
         %{control: control} do
      write =
        "printf 'stray\\n' > stray.txt && mkdir -p mix_lock_user501 && printf 'lock\\n' > mix_lock_user501/lock_0 && " <>
          "mkdir -p #{@approved}/evidence/__pycache__ && printf 'pyc' > #{@approved}/evidence/__pycache__/probe.pyc"

      assert :ok = stray_build(control, [{"FAKE_STRAY_WRITE", write}])

      # Keep this historical test ID; only the Approved-copy addition now
      # triggers guard rework, and the two ordinary extras are disclosed.

      assert sessions(control) == ["launch dev-session-1", "rework dev-session-1"]

      prompt = state!(control, "stray-rework-prompt-1")

      assert listed(prompt) == [{:delete, "#{@approved}/evidence"}]

      assert prompt =~ "Outer Developer resumptions left: 1 of 2"
      assert prompt =~ "restores the frozen package"
      assert prompt =~ "Delete or restore exactly these paths"

      for forbidden <- ~w(clean stash reset checkout restore),
          do: assert(prompt =~ "`git #{forbidden}`")

      assert prompt =~ "never override TMPDIR"

      [attempt] = Candidate.record(control)["attempts"]
      assert [entry] = attempt["guard_violations"]
      assert entry["paths"] == ["#{@approved}/evidence"]
      assert entry["cycle"] == 0
      work = entry["developer_notes"]["text"]
      assert is_binary(work) and work != "" and work != @cleanup
      assert Enum.map(attempt["verification"]["cycles"], & &1["status"]) == ["passed"]

      assert Enum.map(attempt["repair_disclosures"]["items"], & &1["path"]) == [
               "mix_lock_user501/lock_0",
               "stray.txt"
             ]

      packet = packet!(control, attempt)
      assert Enum.map(packet["guard_violations"], & &1["paths"]) == [["#{@approved}/evidence"]]

      assert Enum.map(packet["repair_disclosures"]["items"], & &1["path"]) == [
               "mix_lock_user501/lock_0",
               "stray.txt"
             ]

      assert File.read!(Path.join(control, "stray.txt")) == "stray\n"
      assert File.read!(Path.join(control, "mix_lock_user501/lock_0")) == "lock\n"
    end

    test "a modified tracked file is restored with the prompt's git show and chmod command",
         %{control: control} do
      baseline = File.read!(Path.join(control, "README.md"))

      assert :ok =
               stray_build(control, [{"FAKE_STRAY_WRITE", "printf 'edited\\n' > README.md"}])

      # The historical test title is retained; ordinary tracked extras now
      # reach Review with their diff and are published after acceptance.
      assert sessions(control) == ["launch dev-session-1"]
      assert File.read!(Path.join(control, "README.md")) == "edited\n"
      assert File.read!(Path.join(control, "README.md")) != baseline
      [attempt] = Candidate.record(control)["attempts"]
      refute Map.has_key?(attempt, "guard_violations")
      assert [%{"path" => "README.md", "hunks" => hunks}] = attempt["repair_disclosures"]["items"]
      assert hunks =~ "+edited"
    end

    test "a mode-only change is undone by the same restore command (2b)", %{control: control} do
      tools = Fixture.tmp_dir!("review-wait")
      reviewer = review_waiting_role!(tools, Fixture.support("fake_codex_simple_accept"))

      task =
        Task.async(fn ->
          stray_build(control, [
            {"FAKE_STRAY_WRITE", "chmod 755 README.md"},
            {"FAKE_STRAY_WRAPPED", reviewer}
          ])
        end)

      home = await_file!(control, "harness/*/review-waiting")
      worktree = Candidate.worktree(control)

      # The ordinary extra is carried into Review with its actual mode diff.
      assert Bitwise.band(File.stat!(Path.join(worktree, "README.md")).mode, 0o777) == 0o755

      assert Fixture.git!(worktree, ["diff", "--raw", "HEAD", "--", "README.md"]) =~
               "100644 100755"

      File.write!(Path.join(home, "review-go"), "")
      assert :ok = Task.await(task, 180_000)

      [attempt] = Candidate.record(control)["attempts"]
      refute Map.has_key?(attempt, "guard_violations")
      assert [%{"path" => "README.md", "hunks" => hunks}] = attempt["repair_disclosures"]["items"]
      assert hunks =~ "100644"
      assert sessions(control) == ["launch dev-session-1"]
    end

    test "a provider failure after the rework turn cleaned up retries the same session with the rework prompt",
         %{control: control} do
      assert :ok =
               stray_build(control, [
                 {"FAKE_STRAY_WRITE",
                  "mkdir -p #{@approved}/evidence && printf 'stray\\n' > #{@approved}/evidence/probe.txt"},
                 {"FAKE_STRAY_REWORK", "clean_then_capacity"}
               ])

      assert sessions(control) == [
               "launch dev-session-1",
               "rework dev-session-1",
               "rework dev-session-1"
             ]

      # The controller's one provider retry resent the guard-rework prompt,
      # not the launch prompt.
      assert state!(control, "stray-rework-prompt-2") == state!(control, "stray-rework-prompt-1")

      [attempt] = Candidate.record(control)["attempts"]

      assert [%{"role" => "developer", "session_id" => "dev-session-1"}] =
               attempt["provider_retries"]

      assert [%{"paths" => ["#{@approved}/evidence"]}] = attempt["guard_violations"]
    end
  end

  describe "stray-file-budget-spent" do
    test "(a) a Developer that never cleans up is resumed exactly twice, then stops as guard-violation",
         %{control: control} do
      # The fixture keeps its `offline_retries: 4` default.
      assert File.read!(Path.join(control, ".kogen/config.yaml")) =~ "offline_retries: 4"

      assert {:error, reason} =
               stray_build(control, [
                 {"FAKE_STRAY_WRITE",
                  "mkdir -p #{@approved}/evidence && printf 'stray\\n' > #{@approved}/evidence/probe.txt"},
                 {"FAKE_STRAY_REWORK", "ignore"}
               ])

      assert String.starts_with?(reason, @stray_prefix <> "#{@approved}/evidence/probe.txt;")
      assert owner_status(control) == "stopped: guard-violation"
      assert state!(control, "stray-reworks") == "2\n"

      assert sessions(control) == [
               "launch dev-session-1",
               "rework dev-session-1",
               "rework dev-session-1"
             ]

      assert state!(control, "stray-rework-prompt-2") =~
               "Outer Developer resumptions left: 0 of 2"

      record = Candidate.record(control)
      assert [attempt] = record["attempts"]
      assert length(attempt["guard_violations"]) == 3

      assert Enum.all?(
               attempt["guard_violations"],
               &(&1["paths"] == ["#{@approved}/evidence"])
             )

      refute Map.has_key?(attempt, "verification")
      refute Map.has_key?(attempt, "offline_failures")

      assert File.exists?(
               Path.join(Candidate.worktree(control), "#{@approved}/evidence/probe.txt")
             )

      assert Candidate.candidate(control)["disposition"] == "retained"
    end

    test "(b) a guard rework spends no offline retry: the first failed cycle still has 3 of 4 left",
         %{} do
      control = Fixture.create!(guards: ["dummy.txt", "reviewer-rework-marker.txt"])
      on_exit(fn -> File.rm_rf(control) end)

      assert :ok =
               stray_build(control, [
                 {"FAKE_STRAY_WRAPPED", Fixture.support("fake_codex")},
                 {"FAKE_STRAY_WRITE",
                  "mkdir -p #{@approved}/evidence && printf 'stray\\n' > #{@approved}/evidence/probe.txt"}
               ])

      assert state!(control, "stray-reworks") == "1\n"

      assert state!(control, "verification-resume-prompts") =~
               "Offline (`offline_retries`) retries left: 3 of 4"

      [attempt | _] = Candidate.record(control)["attempts"]
      assert [%{"paths" => ["#{@approved}/evidence"]}] = attempt["guard_violations"]
      assert Enum.map(attempt["verification"]["cycles"], & &1["status"]) == ["failed", "passed"]
      assert attempt["verification"]["offline_failures"] == 1
    end
  end

  describe "terminal-guard-failures-stay-terminal" do
    for {label, write, category, message} <- [
          {"(a) a root .gitignore append",
           "printf 'hidden.txt\\n' >> .gitignore && printf 'hidden\\n' > hidden.txt",
           "git-policy",
           "Candidate ignore files newly hid Candidate paths during Developer turn: hidden.txt"},
          {"(a2) a .gitmodules edit", "printf '[submodule \"x\"]\\n' > .gitmodules", "git-policy",
           "Git configuration or ignore policy changed during Developer turn"},
          {"(b) a .codex/hooks/check.sh edit", "printf '# x\\n' >> .codex/hooks/check.sh",
           "protected-path", @stray_prefix <> ".codex/hooks/check.sh"},
          {"(c) a .codex/hooks.json edit", "printf ' ' >> .codex/hooks.json", "protected-path",
           @stray_prefix <> ".codex/hooks.json"},
          {"(c2) an added .codex/config.toml", "printf 'x = 1\\n' > .codex/config.toml",
           "protected-path", @stray_prefix <> ".codex/config.toml"},
          {"(d) an added .claude/settings.json",
           "mkdir -p .claude && printf '{}' > .claude/settings.json", "protected-path",
           @stray_prefix <> ".claude/settings.json"},
          {"(d2) an added .claude/hooks script",
           "mkdir -p .claude/hooks && printf 'x' > .claude/hooks/on_stop.sh", "protected-path",
           @stray_prefix <> ".claude/hooks/on_stop.sh"},
          {"(d3) an added .claude/agents file",
           "mkdir -p .claude/agents && printf 'x' > .claude/agents/helper.md", "protected-path",
           @stray_prefix <> ".claude/agents/helper.md"},
          {"(d4) an added .claude/commands file",
           "mkdir -p .claude/commands && printf 'x' > .claude/commands/run.md", "protected-path",
           @stray_prefix <> ".claude/commands/run.md"},
          {"(d5) an added .claude/skills file",
           "mkdir -p .claude/skills/probe && printf 'x' > .claude/skills/probe/SKILL.md",
           "protected-path", @stray_prefix <> ".claude/skills/probe/SKILL.md"},
          {"(d6) a stray file with an added .claude/skills file",
           "printf 's' > stray.txt && mkdir -p .claude/skills/probe && printf 'x' > .claude/skills/probe/SKILL.md",
           "protected-path", ".claude/skills/probe/SKILL.md"},
          {"(e) a modified Approved-copy file", "printf 'x\\n' >> #{@approved}/intent.yaml",
           "integrity", "Approved Intent changed during Build"},
          {"(e2) a deleted Approved-copy file", "rm #{@approved}/scenarios.yaml", "integrity",
           "Approved Intent changed during Build"},
          {"(g) a stray file with a .codex/hooks.json edit",
           "printf 's' > stray.txt && printf ' ' >> .codex/hooks.json", "protected-path",
           ".codex/hooks.json"}
        ] do
      test "#{label} stops after the first turn with zero resumes as #{category}",
           %{control: control} do
        assert {:error, reason} =
                 stray_build(control, [{"FAKE_STRAY_WRITE", unquote(write)}])

        message = unquote(message)

        if String.starts_with?(message, @stray_prefix) or not String.contains?(message, "/"),
          do: assert(String.starts_with?(reason, message)),
          else: assert(String.starts_with?(reason, @stray_prefix) and reason =~ message)

        assert owner_status(control) == "stopped: #{unquote(category)}"
        assert sessions(control) == ["launch dev-session-1"]
        refute File.exists?(Candidate.fake_state(control, "stray-reworks"))
        [attempt] = Candidate.record(control)["attempts"]
        refute Map.has_key?(attempt, "guard_violations")
        refute Map.has_key?(attempt, "verification")
      end
    end

    test "(f) a failed turn that leaves a stray file stops with the guard message as integrity",
         %{control: control} do
      assert {:error, reason} =
               stray_build(control, [
                 {"FAKE_STRAY_WRITE", "printf 's' > stray.txt"},
                 {"FAKE_STRAY_EXIT", "3"}
               ])

      assert reason =~ "harness failure during Developer turn"
      assert owner_status(control) == "stopped: provider-failure"
      assert sessions(control) == ["launch dev-session-1"]
      [attempt] = Candidate.record(control)["attempts"]
      refute Map.has_key?(attempt, "guard_violations")
    end

    test "(f2) a rework turn that fails with a capacity marker before cleaning up stops as integrity without a retry",
         %{control: control} do
      assert {:error, reason} =
               stray_build(control, [
                 {"FAKE_STRAY_WRITE",
                  "mkdir -p #{@approved}/evidence && printf 's' > #{@approved}/evidence/probe.txt"},
                 {"FAKE_STRAY_REWORK", "capacity"}
               ])

      assert String.starts_with?(reason, "Approved Intent changed during Build")
      assert owner_status(control) == "stopped: integrity"
      assert sessions(control) == ["launch dev-session-1", "rework dev-session-1"]
      [attempt] = Candidate.record(control)["attempts"]
      refute Map.has_key?(attempt, "provider_retries")
      assert [%{"paths" => ["#{@approved}/evidence"]}] = attempt["guard_violations"]
    end

    test "(h) a Claude scheduled_tasks.lock is reworked like any stray path", %{control: control} do
      write = "mkdir -p .claude && printf 'lock' > .claude/scheduled_tasks.lock"
      assert :ok = stray_build(control, [{"FAKE_STRAY_WRITE", write}])
      [attempt] = Candidate.record(control)["attempts"]

      # Keep the historical test ID; this ordinary lock file now has a
      # separate Reviewer disclosure and does not consume guard rework.
      refute Map.has_key?(attempt, "guard_violations")

      assert [%{"path" => ".claude/scheduled_tasks.lock"}] =
               attempt["repair_disclosures"]["items"]
    end

    test "(i) a nested .pytest_cache/.gitignore is an ordinary stray path", %{control: control} do
      write =
        "mkdir -p .pytest_cache/v/cache && printf '*\\n' > .pytest_cache/.gitignore && " <>
          "printf '{}' > .pytest_cache/v/cache/lastfailed"

      assert {:error, reason} = stray_build(control, [{"FAKE_STRAY_WRITE", write}])
      assert reason =~ "Candidate ignore files newly hid Candidate paths during Developer turn"
      assert reason =~ ".pytest_cache/v/cache/lastfailed"
      assert owner_status(control) == "stopped: git-policy"
    end
  end

  describe "shared-git-files-do-not-stop" do
    test "(a) control's .git/config and .git/info/exclude changes are recorded once and the Build is accepted",
         %{control: control} do
      role =
        Fixture.waiting_role!(
          Fixture.tmp_dir!("shared-a"),
          Fixture.support("fake_stray_writer_role")
        )

      task =
        Task.async(fn ->
          Fixture.build!(control,
            harness: role,
            env: [{"FAKE_STRAY_WRITE", "printf 's' > stray.txt"}]
          )
        end)

      home = Fixture.await_waiting!(control)
      change_shared_files!(control, "/no-such-path")
      File.write!(Path.join(home, "go"), "")
      assert :ok = Task.await(task, 180_000)

      [attempt] = Candidate.record(control)["attempts"]
      refute Map.has_key?(attempt, "guard_violations")
      assert [%{"path" => "stray.txt"}] = attempt["repair_disclosures"]["items"]
      events = attempt["environment_events"]
      assert Enum.map(events, & &1["file"]) == [".git/config", ".git/info/exclude"]

      for event <- events do
        assert event["before"] != event["after"]
        assert event["after"] =~ ~r/^[0-9a-f]{64}$/
      end

      assert Enum.map(attempt["verification"]["cycles"], & &1["status"]) == ["passed"]
    end

    for {label, guards} <- [{"(b)", ["dummy.txt"]}, {"(b2)", ["dummy.txt", "hidden.txt"]}] do
      test "#{label} a new exclude rule hiding a Candidate file stops as git-policy with guards #{inspect(guards)}",
           %{} do
        control = Fixture.create!(guards: unquote(guards))
        on_exit(fn -> File.rm_rf(control) end)

        role =
          Fixture.waiting_role!(
            Fixture.tmp_dir!("shared-b"),
            Fixture.support("fake_stray_writer_role")
          )

        task =
          Task.async(fn ->
            Fixture.build!(control,
              harness: role,
              env: [{"FIXTURE_DEV_EDIT", "printf 'hidden\\n' > hidden.txt"}]
            )
          end)

        home = Fixture.await_waiting!(control)
        change_shared_files!(control, "/hidden.txt")
        File.write!(Path.join(home, "go"), "")
        assert {:error, reason} = Task.await(task, 180_000)

        assert String.starts_with?(
                 reason,
                 "Control's .git/info/exclude changed the ignored state of Candidate paths: hidden.txt;"
               )

        assert owner_status(control) == "stopped: git-policy"
        [attempt] = Candidate.record(control)["attempts"]

        assert Enum.map(attempt["environment_events"], & &1["file"]) == [
                 ".git/config",
                 ".git/info/exclude"
               ]

        refute Map.has_key?(attempt, "guard_violations")
      end
    end

    test "(c) a failed turn after a .git/config change keeps today's harness failure and records the event",
         %{control: control} do
      failing =
        Fixture.fake!(
          Fixture.tmp_dir!("failing"),
          "failing_role",
          "#!/bin/sh\ncat >/dev/null\nexit 3\n"
        )

      role = Fixture.waiting_role!(Fixture.tmp_dir!("shared-c"), failing)
      task = Task.async(fn -> Fixture.build!(control, harness: role) end)
      home = Fixture.await_waiting!(control)
      Fixture.git!(control, ["config", "branch.develop.vscode-merge-base", "origin/main"])
      File.write!(Path.join(home, "go"), "")
      assert {:error, reason} = Task.await(task, 180_000)

      assert reason =~ "harness failure during Developer turn"
      refute reason =~ "Git configuration or ignore policy changed"
      [attempt] = Candidate.record(control)["attempts"]
      assert [%{"file" => ".git/config"}] = attempt["environment_events"]
    end
  end

  describe "approved-addition-outside-turn-is-integrity" do
    for {label, status} <- [{"(a) passes", "0"}, {"(b) fails", "1"}] do
      test "a check that adds an Approved-copy entry and #{label} stops as integrity with no Developer resume",
           %{control: control} do
        File.write!(Path.join(control, "Makefile"), """
        .PHONY: check
        check:
        \t@mkdir -p #{@approved} && printf 'extra\\n' > #{@approved}/extra.txt
        \t@exit #{unquote(status)}
        """)

        Fixture.git!(control, ["commit", "-qam", "check adds an Approved entry"])

        assert {:error, reason} =
                 stray_build(control, [
                   {"FAKE_STRAY_WRAPPED", Fixture.support("fake_codex")},
                   {"FAKE_CHECK_FAIL", "0"}
                 ])

        assert String.starts_with?(reason, "Approved Intent changed during Build")
        assert owner_status(control) == "stopped: integrity"
        assert sessions(control) == ["launch dev-session-1"]
        refute File.exists?(Candidate.fake_state(control, "verification-resume-prompts"))
        refute File.exists?(Candidate.fake_state(control, "developer-resume-prompts"))
        [attempt] = Candidate.record(control)["attempts"]
        refute Map.has_key?(attempt, "guard_violations")
      end
    end
  end

  describe "reviewer-sees-guard-violations" do
    test "the review packet carries the reworked paths; a Build without a rework carries []",
         %{control: control} do
      write =
        "printf 's' > stray.txt && mkdir -p mix_lock_user501 && printf 'l' > mix_lock_user501/lock_0 && " <>
          "mkdir -p #{@approved}/evidence/__pycache__ && printf 'p' > #{@approved}/evidence/__pycache__/probe.pyc"

      assert :ok = stray_build(control, [{"FAKE_STRAY_WRITE", write}])
      record = Candidate.record(control)
      [attempt] = record["attempts"]
      packet = packet!(control, attempt)
      paths = ["#{@approved}/evidence"]
      encoded = ReviewPacket.encode(paths)

      assert [object] = packet["guard_violations"]

      assert object == %{
               "cycle" => 0,
               "path_count" => 1,
               "paths" => paths,
               "sha256" => sha256(encoded),
               "byte_count" => byte_size(encoded),
               "locator" => "/attempts/0/guard_violations/0/paths"
             }

      refute Enum.any?(
               packet["omitted"],
               &String.starts_with?(&1["field"] || "", "/guard_violations")
             )

      assert packet["repair_disclosures"]["item_count"] == 2

      assert Enum.map(packet["repair_disclosures"]["items"], & &1["path"]) == [
               "mix_lock_user501/lock_0",
               "stray.txt"
             ]

      clean = Fixture.create!()
      on_exit(fn -> File.rm_rf(clean) end)
      assert :ok = Fixture.build!(clean)
      [clean_attempt] = Candidate.record(clean)["attempts"]
      assert packet!(clean, clean_attempt)["guard_violations"] == []
    end
  end

  describe "work-turn-notes-survive-rework" do
    test "(a) Jev reads the work turn's and the cleanup turn's notes once, combined under controller headers",
         %{control: control} do
      jev_log = Path.join(Fixture.tmp_dir!("jev-log"), "log")

      assert :ok =
               stray_build(control, [
                 {"FAKE_STRAY_WRITE",
                  "mkdir -p #{@approved}/evidence && printf 's' > #{@approved}/evidence/probe.txt"},
                 {"FAKE_JEV_LOG_DIR", jev_log}
               ])

      [attempt] = Candidate.record(control)["attempts"]
      [entry] = attempt["guard_violations"]
      work = entry["developer_notes"]["text"]
      assert work != @cleanup
      combined = "#{@work_header}\n#{work}\n\n#{@passed_header}\n#{@cleanup}"

      assert [request] = jev_requests(jev_log)
      assert request["state"]["developer_notes"] == combined
      assert attempt["developer_notes"]["text"] == combined
      assert packet!(control, attempt)["developer_notes"] == combined
    end

    test "(b) a work turn's objection read after the rework stops as cannot-comply before any cycle",
         %{control: control} do
      assert {:error, reason} =
               stray_build(control, [
                 {"FAKE_STRAY_WRITE",
                  "mkdir -p #{@approved}/evidence && printf 's' > #{@approved}/evidence/probe.txt"},
                 {"FAKE_JEV_ANSWERS",
                  ~s({"objection:scenario:fixture-scenario": ["objection", 0.99]})}
               ])

      assert reason =~ "Developer cannot comply as approved; return to Shaping:"
      assert owner_status(control) == "stopped: cannot-comply"
      [attempt] = Candidate.record(control)["attempts"]
      [entry] = attempt["guard_violations"]
      work = entry["developer_notes"]["text"]
      assert reason =~ work
      assert reason =~ @work_header
      refute Map.has_key?(attempt, "verification")
    end
  end

  describe "rework-still-runs-every-input-check" do
    test "an Approved-copy addition with a .codex/hooks.json edit stops as protected-path",
         %{control: control} do
      write = "printf 'x' > #{@approved}/extra.txt && printf ' ' >> .codex/hooks.json"
      assert {:error, reason} = stray_build(control, [{"FAKE_STRAY_WRITE", write}])
      assert String.starts_with?(reason, @stray_prefix)
      assert reason =~ ".codex/hooks.json"
      assert owner_status(control) == "stopped: protected-path"
      assert sessions(control) == ["launch dev-session-1"]
    end

    test "an Approved-copy addition with a rewritten retained record version stops with that input's integrity message",
         %{control: control} do
      # The first Review cites the Build's own tracking record (retaining a
      # record version) and asks for rework; the reworking Developer turn
      # adds an Approved-copy entry and rewrites that retained record
      # version, an input checked after approved_unchanged/1.
      role = citing_tamper_role!(Fixture.tmp_dir!("citing-tamper"), control)

      task = Task.async(fn -> Fixture.build!(control, harness: role) end)
      home = Fixture.await_waiting!(control)

      for f <-
            Path.wildcard(
              Path.join(control, ".kogen/runtime/scenario-tracking/*/record-versions/*.json")
            ) do
        File.write!(f, "tampered")
      end

      File.write!(Path.join(home, "go"), "")
      assert {:error, reason} = Task.await(task, 180_000)

      assert String.starts_with?(reason, "record version sidecar mutated")
      assert owner_status(control) == "stopped: integrity"
      assert File.exists?(Path.join(Candidate.worktree(control), "#{@approved}/extra.txt"))

      attempts = Candidate.record(control)["attempts"]
      assert length(attempts) == 2
      for attempt <- attempts, do: refute(Map.has_key?(attempt, "guard_violations"))
    end
  end

  # Reviewer 1 cites the tracking record and asks for rework, Reviewer 2
  # accepts; a resumed Developer turn (the Review rework) adds an entry to
  # the Approved copy and rewrites every retained record version.
  defp citing_tamper_role!(dir, _control) do
    Fixture.fake!(dir, "citing_tamper_role", """
    #!/bin/sh
    set -eu
    next=#{inspect(Fixture.support("fake_codex_simple_accept"))}
    helper=#{inspect(Fixture.support("scenario_response.py"))}
    if [ "${KOGEN_ROLE:-}" = reviewer ]; then
      input="$(cat)"
      printf '%s' "$input" | python3 -B #{inspect(Fixture.support("launch_receipt.py"))} "$@"
      out=; prev=
      for a in "$@"; do [ "$prev" = --output-last-message ] && out="$a"; prev="$a"; done
      n=$(cat "$KOGEN_HARNESS_HOME/citing-reviews" 2>/dev/null || echo 0)
      # An evidence addendum resumes the accepting session: not a new Review.
      case "$input" in KOGEN_EVIDENCE_ADDENDUM*) addendum=1 ;; *) addendum=0; n=$((n + 1)); echo "$n" > "$KOGEN_HARNESS_HOME/citing-reviews" ;; esac
      verdict=accept; [ "$n" = 1 ] && [ "$addendum" = 0 ] && verdict=rework
      tracking="$(printf '%s' "$input" | python3 -B -c 'import json,sys; lines=sys.stdin.read().splitlines(); i=max(i for i,v in enumerate(lines) if v=="KOGEN_TASK_CONTEXT"); print(json.loads(lines[i+1])["tracking_path"])')"
      printf '%s' "$input" | python3 -B "$helper" reviewer "$verdict" |
        python3 -B -c 'import json,sys; v=json.load(sys.stdin); t=sys.argv[1]; ev=[{"path":t[t.index(".kogen/runtime/"):],"locator":"the Build own tracking record","receipt":None}]; v["scenarios"][0]["evidence"]=ev; [f.__setitem__("evidence", ev) for f in v.get("findings", [])]; print(json.dumps(v))' "$tracking" >"$out"
      printf '{"type":"thread.started","thread_id":"citing-reviewer-%s"}\\n{"type":"turn.completed","thread_id":"citing-reviewer-%s"}\\n' "$n" "$n"
      exit 0
    fi
    is_resume=0
    resume_id=; previous=; penultimate=; last=
    for a in "$@"; do
      [ "$a" = resume ] && is_resume=1
      [ "$previous" = --output-last-message ] && output="$a"
      penultimate="$last"; last="$a"; previous="$a"
    done
    [ "$is_resume" = 1 ] && resume_id="dev-session-1"
    output="$KOGEN_HARNESS_HOME/citing-output-$$"
    if [ "$is_resume" = 1 ]; then
      : > "$KOGEN_HARNESS_HOME/waiting"
      i=0
      while [ ! -f "$KOGEN_HARNESS_HOME/go" ] && [ "$i" -lt 2400 ]; do sleep 0.05; i=$((i + 1)); done
      printf 'x' > #{@approved}/extra.txt
      printf '{"type":"thread.started","thread_id":"%s"}\n' "$resume_id"
      printf '{"type":"item.completed","item":{"type":"agent_message","text":"tampered inputs"}}\n'
      printf '{"type":"turn.completed","thread_id":"%s"}\n' "$resume_id"
      exit 0
    fi
    "$next" "$@" > "$output"
    cat "$output"
    rm -f "$output"
    """)
  end

  defp stray_build(control, env) do
    Fixture.build!(control, harness: Fixture.support("fake_stray_writer_role"), env: env)
  end

  defp sessions(control) do
    case File.read(Candidate.fake_state(control, "stray-sessions")) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp state!(control, name), do: File.read!(Candidate.fake_state(control, name))

  defp listed(prompt) do
    prompt
    |> String.split("\n")
    |> Enum.flat_map(fn
      "- delete: `" <> rest -> [{:delete, String.trim_trailing(rest, "`")}]
      "- restore: `" <> rest -> [{:restore, String.trim_trailing(rest, "`")}]
      _ -> []
    end)
  end

  defp owner_status(control) do
    [owner] = Fixture.owner_records(control)
    owner["status"]
  end

  defp packet!(control, attempt) do
    control |> Path.join(attempt["review_packet"]["path"]) |> File.read!() |> Jason.decode!()
  end

  defp jev_requests(dir) do
    dir
    |> Path.join("request-*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(fn path ->
      path |> File.read!() |> Jason.decode!() |> Map.fetch!("body") |> Jason.decode!()
    end)
  end

  defp change_shared_files!(control, exclude_line) do
    File.write!(
      Path.join(control, ".git/config"),
      "[branch \"develop\"]\n\tvscode-merge-base = origin/main\n",
      [:append]
    )

    exclude = Path.join(control, ".git/info/exclude")
    File.mkdir_p!(Path.dirname(exclude))
    File.write!(exclude, exclude_line <> "\n", [:append])
  end

  # Wraps `next`: a Reviewer launch signals `<harness home>/review-waiting`
  # and waits for `<harness home>/review-go`, so the test can inspect the
  # Candidate between the last Developer turn and publication.
  defp review_waiting_role!(dir, next) do
    Fixture.fake!(dir, "review_waiting_role", """
    #!/bin/sh
    if [ "${KOGEN_ROLE:-}" = reviewer ] && [ ! -f "$KOGEN_HARNESS_HOME/review-go" ]; then
      : > "$KOGEN_HARNESS_HOME/review-waiting"
      i=0
      while [ ! -f "$KOGEN_HARNESS_HOME/review-go" ] && [ "$i" -lt 2400 ]; do sleep 0.05; i=$((i + 1)); done
    fi
    exec #{inspect(next)} "$@"
    """)
  end

  defp await_file!(control, pattern, attempts \\ 2400) do
    case Path.wildcard(Path.join(Fixture.project_dir(control), pattern)) do
      [file] ->
        Path.dirname(file)

      [] when attempts > 0 ->
        Process.sleep(50)
        await_file!(control, pattern, attempts - 1)

      other ->
        raise "never found #{pattern}: #{inspect(other)}"
    end
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
