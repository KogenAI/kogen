defmodule Kogen.ClaudeCodeHarnessTest do
  @moduledoc """
  The Claude Code adapter behind `Kogen.Harness`, driven with a scripted fake
  `claude` that records argv, environment and stdin and replays a stream-json
  capture. No provider is contacted.
  """
  use Kogen.IsolatedCase, async: true

  alias Kogen.Build.WriteBoundary
  alias Kogen.ClaudeCode
  alias Kogen.Harness
  alias Kogen.Harness.Claude

  @config %{
    harness: "claude",
    helpers: %{
      scout: %{model: "claude-sonnet-5", effort: "low"},
      worker: %{model: "claude-sonnet-5", effort: "medium"},
      expert: %{model: "claude-opus-5-5", effort: "high"}
    }
  }

  @notes "Implemented the plan and left the Candidate ready for review."
  @verdict %{
    "candidate_id" => "cand",
    "attempt_token" => "tok",
    "verdict" => "accept",
    "scenarios" => [],
    "dispositions" => [],
    "findings" => []
  }

  setup do
    dir = Path.join(System.tmp_dir!(), "kogen-cc-harness-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    executable = Path.join(dir, "claude")

    File.write!(executable, """
    #!/bin/sh
    d="#{dir}"
    : > "$d/argv"; for a in "$@"; do printf '%s\\n' "$a" >> "$d/argv"; done
    env > "$d/env"
    if [ "$1" = -p ]; then cat > "$d/stdin"; fi
    session=; previous=
    for a in "$@"; do
      [ "$previous" = --session-id ] && session="$a"
      [ "$previous" = --resume ] && session="$a"
      previous="$a"
    done
    [ -n "${FAKE_SESSION:-}" ] && session="$FAKE_SESSION"
    sed "s/@SESSION@/$session/g" "$d/stream"
    exit "${FAKE_EXIT:-0}"
    """)

    File.chmod!(executable, 0o755)

    context = %{
      harness: "claude",
      executable: executable,
      args: [],
      env: ClaudeCode.environment(%{path: Path.join(dir, "scope")}),
      config: @config,
      project: dir
    }

    %{dir: dir, context: context}
  end

  defp stream!(dir, events) do
    File.write!(
      Path.join(dir, "stream"),
      Enum.map_join(events, "\n", &Jason.encode!/1) <> "\n"
    )
  end

  defp init, do: %{"type" => "system", "subtype" => "init", "session_id" => "@SESSION@"}

  defp root(model, content),
    do: %{
      "type" => "assistant",
      "session_id" => "@SESSION@",
      "parent_tool_use_id" => nil,
      "message" => %{"model" => model, "content" => content}
    }

  defp result(extra),
    do:
      Map.merge(
        %{
          "type" => "result",
          "subtype" => "success",
          "is_error" => false,
          "session_id" => "@SESSION@",
          "terminal_reason" => "completed"
        },
        extra
      )

  defp argv(dir), do: dir |> Path.join("argv") |> File.read!() |> String.split("\n", trim: true)

  defp flag(argv, name) do
    index = Enum.find_index(argv, &(&1 == name))
    index && Enum.at(argv, index + 1)
  end

  defp run(context, fun, env) do
    Enum.each(env, fn {k, v} -> System.put_env(k, v) end)

    try do
      fun.(context)
    after
      Enum.each(env, fn {k, _} -> System.delete_env(k) end)
    end
  end

  describe "Developer turns" do
    test "a fresh turn uses -p stream-json, a Kogen session id, exact profile, hooks and no schema",
         %{dir: dir, context: context} do
      stream!(dir, [
        init(),
        root("claude-opus-5-5", [%{"type" => "text", "text" => @notes}]),
        result(%{"result" => @notes})
      ])

      assert {:ok, turn} =
               Harness.launch_build_developer(
                 "PROMPT",
                 "claude-opus-5-5",
                 "medium",
                 [{"KOGEN_VERIFICATION_CONTEXT", "/ctx"}],
                 context
               )

      args = argv(dir)
      assert Enum.take(args, 4) == ["-p", "--output-format", "stream-json", "--verbose"]
      session = flag(args, "--session-id")
      assert session =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
      assert turn.session_id == session
      refute "--resume" in args
      refute "--json-schema" in args
      refute Enum.any?(args, &String.contains?(&1, "fallback"))
      assert flag(args, "--model") == "claude-opus-5-5"
      assert flag(args, "--effort") == "medium"
      assert "--dangerously-skip-permissions" in args
      assert flag(args, "--setting-sources") == "project"
      assert "--strict-mcp-config" in args

      for agent <- ~w(general-purpose Explore Plan claude statusline-setup),
          do: assert("Agent(#{agent})" in args)

      refute "Edit" in args

      settings = args |> flag("--settings") |> Jason.decode!()
      [stop] = settings["hooks"]["Stop"]
      assert hd(stop["hooks"])["command"] =~ ".codex/hooks/check.sh"
      [pre] = settings["hooks"]["PreToolUse"]
      assert pre["matcher"] == "Bash"
      assert hd(pre["hooks"])["command"] =~ ".codex/hooks/verification_policy.py"

      env = File.read!(Path.join(dir, "env"))
      assert env =~ "KOGEN_ROLE=developer"
      assert env =~ "KOGEN_VERIFICATION_CONTEXT=/ctx"
      assert env =~ "DISABLE_AUTOUPDATER=1"
      assert env =~ "CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT=1\n"

      stdin = File.read!(Path.join(dir, "stdin"))
      assert stdin == "PROMPT"
      refute stdin =~ "schema"

      assert turn.message == @notes
      assert turn.invocation_evidence.outcome == :settled
      refute Map.has_key?(turn.invocation_evidence, :schema)
      refute Map.has_key?(turn.invocation_evidence, :schema_sha256)
      assert turn.invocation_evidence.session_id == session
      assert turn.invocation_evidence.message == @notes
      assert turn.invocation_evidence.message_sha256 == sha(@notes)
      assert turn.executed_models == %{"root" => ["claude-opus-5-5"], "helpers" => []}
    end

    test "a resume uses --resume with the exact id, never mints a session and carries no schema",
         %{dir: dir, context: context} do
      stream!(dir, [init(), result(%{"result" => @notes})])

      assert {:ok, turn} =
               Harness.resume_build_developer(
                 "abc-123",
                 "FEEDBACK",
                 "claude-opus-5-5",
                 "medium",
                 [],
                 context
               )

      assert turn.session_id == "abc-123"
      assert turn.message == @notes
      assert turn.invocation_evidence.message_sha256 == sha(@notes)
      refute Map.has_key?(turn.invocation_evidence, :schema)

      args = argv(dir)
      assert flag(args, "--resume") == "abc-123"
      refute "--session-id" in args
      refute "--json-schema" in args

      stdin = File.read!(Path.join(dir, "stdin"))
      assert stdin == "FEEDBACK"
      refute stdin =~ "schema"
    end

    for {label, message} <- [
          {"empty", ""},
          {"prose", "Done. Everything is ready."},
          {"malformed JSON", ~s({"attempt_token":"tok")}
        ] do
      test "a #{label} final message is settled and passed through as notes, never a typed error",
           %{dir: dir, context: context} do
        message = unquote(message)
        stream!(dir, [init(), root("claude-opus-5-5", []), result(%{"result" => message})])

        assert {:ok, turn} =
                 Harness.launch_build_developer(
                   "p",
                   "claude-opus-5-5",
                   "medium",
                   [],
                   context
                 )

        assert turn.message == message
        assert turn.invocation_evidence.outcome == :settled
        assert turn.invocation_evidence.message == message
        assert turn.invocation_evidence.message_sha256 == sha(message)
        assert turn.invocation_evidence.session_id == flag(argv(dir), "--session-id")
      end
    end

    test "a settled result carrying no result field at all is settled with empty notes",
         %{dir: dir, context: context} do
      stream!(dir, [init(), root("claude-opus-5-5", []), result(%{})])

      assert {:ok, turn} =
               Harness.launch_build_developer("p", "claude-opus-5-5", "medium", [], context)

      assert turn.message == ""
      assert turn.invocation_evidence.message_sha256 == sha("")
    end

    test "the notes are the final result, never intermediate prose", %{
      dir: dir,
      context: context
    } do
      stream!(dir, [
        init(),
        root("claude-opus-5-5", [%{"type" => "text", "text" => @notes}]),
        root("claude-opus-5-5", [%{"type" => "text", "text" => "Stop hook fixed; here is prose."}]),
        result(%{"result" => "Stop hook fixed; here is prose."})
      ])

      assert {:ok, turn} =
               Harness.launch_build_developer("p", "claude-opus-5-5", "medium", [], context)

      assert turn.message == "Stop hook fixed; here is prose."
    end

    test "a resume that reports another session fails closed", %{dir: dir, context: context} do
      stream!(dir, [init(), result(%{"result" => @notes})])

      assert {:error, {:developer_transport_failure, {:session_id_mismatch, mismatch}, evidence}} =
               run(
                 context,
                 &Harness.resume_build_developer(
                   "abc-123",
                   "x",
                   "claude-opus-5-5",
                   "medium",
                   [],
                   &1
                 ),
                 [{"FAKE_SESSION", "other-session"}]
               )

      assert mismatch == %{expected: "abc-123", actual: "other-session"}
      assert evidence.outcome == :provider_failure
    end

    test "resuming a missing session exits 1 and fails closed", %{dir: dir, context: context} do
      File.write!(Path.join(dir, "stream"), "No conversation found with session ID: gone\n")

      assert {:error, {:developer_transport_failure, {:provider_exit, 1, _}, evidence}} =
               run(
                 context,
                 &Harness.resume_build_developer(
                   "gone",
                   "x",
                   "claude-opus-5-5",
                   "medium",
                   [],
                   &1
                 ),
                 [{"FAKE_EXIT", "1"}]
               )

      assert evidence.outcome == :provider_failure
    end

    test "provider errors and missing init or result are transport failures",
         %{dir: dir, context: context} do
      for {events, match} <- [
            {[init(), result(%{"subtype" => "error_during_execution", "is_error" => true})],
             :provider_error},
            {[init()], :no_result_event},
            {[result(%{"result" => @notes})], :no_init_event}
          ] do
        stream!(dir, events)

        assert {:error, {:developer_transport_failure, reason, evidence}} =
                 Harness.launch_build_developer("p", "claude-opus-5-5", "medium", [], context)

        assert elem(reason, 0) == match
        assert evidence.outcome == :provider_failure
      end
    end

    test "a root response from another model fails the turn with a typed error",
         %{dir: dir, context: context} do
      stream!(dir, [
        init(),
        root("claude-sonnet-5", [%{"type" => "text", "text" => @notes}]),
        result(%{"result" => @notes})
      ])

      assert {:error,
              {:developer_transport_failure,
               {:root_model_mismatch, %{expected: "claude-opus-5-5", actual: "claude-sonnet-5"}},
               evidence}} =
               Harness.launch_build_developer("p", "claude-opus-5-5", "medium", [], context)

      assert evidence.outcome == :provider_failure
    end
  end

  describe "executed helper models" do
    test "helper models come from linked messages, never from helper text" do
      events = [
        init(),
        root("claude-opus-5-5", [
          %{
            "type" => "tool_use",
            "id" => "toolu_1",
            "name" => "Agent",
            "input" => %{"subagent_type" => "kogen-scout"}
          }
        ]),
        %{
          "type" => "assistant",
          "parent_tool_use_id" => "toolu_1",
          "message" => %{
            "model" => "claude-sonnet-5",
            "content" => [%{"type" => "text", "text" => "I am running on claude-opus-5-5"}]
          }
        },
        root("<synthetic>", [])
      ]

      assert Claude.executed_models(events) == %{
               "root" => ["claude-opus-5-5"],
               "helpers" => [
                 %{
                   "tool_use_id" => "toolu_1",
                   "agent" => "kogen-scout",
                   "models" => ["claude-sonnet-5"]
                 }
               ]
             }
    end

    test "each role gets configured helper profiles restricted to its authority" do
      developer = Claude.agents("developer", @config.helpers)
      assert developer["kogen-scout"]["tools"] == ~w(Read Grep Glob)
      assert developer["kogen-worker"]["tools"] == ~w(Read Grep Glob Bash Edit Write)
      assert developer["kogen-expert"]["tools"] == ~w(Read Grep Glob Bash)

      for role <- ["reviewer"],
          {_name, agent} <- Claude.agents(role, @config.helpers) do
        assert Enum.all?(agent["tools"], &(&1 not in ~w(Edit Write NotebookEdit Agent)))
      end

      for role <- ["developer", "reviewer", "shaping"] do
        agents = Claude.agents(role, @config.helpers)
        assert Map.keys(agents) == ["kogen-expert", "kogen-scout", "kogen-worker"]

        for {label, profile} <- @config.helpers do
          agent = agents["kogen-#{label}"]
          assert {agent["model"], agent["effort"]} == {profile.model, profile.effort}
          assert agent["prompt"] =~ "Never run or delegate a Kogen verification gate"
        end
      end

      assert Claude.disallowed_tools("reviewer") -- Claude.disallowed_tools("developer") ==
               ~w(Edit Write NotebookEdit)

      assert Claude.disallowed_tools("shaping") ==
               Claude.disallowed_tools("developer") ++
                 ~w(AskUserQuestion ExitPlanMode EnterPlanMode)
    end
  end

  describe "Reviewer" do
    test "a fresh session with --json-schema, no editing tools and a validated verdict",
         %{dir: dir, context: context} do
      raw_logs = Path.join(dir, "raw")

      stream!(dir, [
        init(),
        root("claude-opus-5-5", [%{"type" => "tool_use", "name" => "StructuredOutput"}]),
        result(%{"structured_output" => @verdict, "result" => ""})
      ])

      assert {:ok, verdict} =
               run(
                 context,
                 &Harness.launch_reviewer("REVIEW", "claude-opus-5-5", "medium", &1),
                 [{"KOGEN_RAW_LOG_DIR", raw_logs}]
               )

      args = argv(dir)
      assert verdict.verdict == "accept"
      assert verdict.response == @verdict
      assert verdict.session_id == flag(args, "--session-id")
      refute "--resume" in args
      assert Jason.decode!(flag(args, "--json-schema")) == Jason.decode!(Harness.Verdict.schema())

      for tool <- ["Edit", "Write", "NotebookEdit", "Agent(Explore)"], do: assert(tool in args)
      assert File.read!(Path.join(dir, "env")) =~ "KOGEN_ROLE=reviewer"

      [receipt] =
        raw_logs
        |> Path.join("reviewer-verdicts.jsonl")
        |> File.read!()
        |> String.split("\n", trim: true)

      receipt = Jason.decode!(receipt)
      assert receipt["session_id"] == verdict.session_id
      assert receipt["executed_models"]["root"] == ["claude-opus-5-5"]

      assert {:ok, second} =
               Harness.launch_reviewer("REVIEW", "claude-opus-5-5", "medium", context)

      assert second.session_id != verdict.session_id
    end

    test "success without structured_output, an invalid verdict or a hook stop is malformed",
         %{dir: dir, context: context} do
      for extra <- [
            %{"result" => "{}"},
            %{"structured_output" => Map.delete(@verdict, "findings")},
            %{"structured_output" => @verdict, "terminal_reason" => "hook_stopped"}
          ] do
        stream!(dir, [init(), result(extra)])

        assert {:error, {:malformed_verdict, 0, %{"reviewer_session_id" => _}}} =
                 Harness.launch_reviewer("r", "claude-opus-5-5", "medium", context)
      end
    end
  end

  describe "Shaping Controller turn" do
    defp shaping_context(dir, context, extra \\ %{}) do
      context
      |> Map.put(:log_path, Path.join(dir, "turns/0001.jsonl"))
      |> Map.merge(extra)
    end

    test "a fresh turn runs -p with --session-id, the prompt on stdin, the role and the log",
         %{dir: dir, context: context} do
      uuid = Claude.uuid4()

      stream!(dir, [
        init(),
        root("claude-opus-5-5", [%{"type" => "text", "text" => "ok"}]),
        result(%{"usage" => %{"input_tokens" => 7, "output_tokens" => 2}})
      ])

      env = [{"KOGEN_SHAPING_SESSION", "s-1"} | context.env]
      context = shaping_context(dir, %{context | env: env}, %{channel: "CHANNEL TEXT"})

      assert {:ok, turn} =
               Harness.shaping_turn({:fresh, uuid}, "SHAPE", "claude-opus-5-5", "medium", context)

      assert turn == %{
               provider_session_id: uuid,
               exit_code: 0,
               usage: %{"input_tokens" => 7, "output_tokens" => 2},
               timed_out: false
             }

      args = argv(dir)
      assert Enum.take(args, 4) == ["-p", "--output-format", "stream-json", "--verbose"]
      assert flag(args, "--session-id") == uuid
      refute "--resume" in args
      assert flag(args, "--append-system-prompt") == "CHANNEL TEXT"
      assert flag(args, "--model") == "claude-opus-5-5"
      assert "AskUserQuestion" in args
      assert File.read!(Path.join(dir, "stdin")) == "SHAPE"
      environment = File.read!(Path.join(dir, "env"))
      assert environment =~ "KOGEN_ROLE=shaping"
      assert environment =~ "KOGEN_SHAPING_SESSION=s-1"
      assert File.read!(context.log_path) =~ ~s("subtype":"init")
    end

    test "a resume uses --resume with the same id and no channel by default",
         %{dir: dir, context: context} do
      stream!(dir, [init(), root("claude-opus-5-5", []), result(%{})])

      assert {:ok, %{provider_session_id: "abc-123", usage: nil}} =
               Harness.shaping_turn(
                 {:resume, "abc-123"},
                 "MORE",
                 "claude-opus-5-5",
                 "medium",
                 shaping_context(dir, context)
               )

      args = argv(dir)
      assert flag(args, "--resume") == "abc-123"
      refute "--session-id" in args
      refute "--append-system-prompt" in args
    end

    test "a different init session is a provider_session_mismatch", %{dir: dir, context: context} do
      stream!(dir, [init(), root("claude-opus-5-5", []), result(%{})])

      result =
        run(
          shaping_context(dir, context),
          &Harness.shaping_turn({:resume, "wanted"}, "p", "claude-opus-5-5", "medium", &1),
          [{"FAKE_SESSION", "other"}]
        )

      assert {:error, {:provider_session_mismatch, %{expected: "wanted", actual: "other"}}} =
               result
    end

    test "No conversation found on resume is provider_session_unavailable",
         %{dir: dir, context: context} do
      File.write!(Path.join(dir, "stream"), "No conversation found with session ID: gone\n")

      result =
        run(
          shaping_context(dir, context),
          &Harness.shaping_turn({:resume, "gone"}, "p", "claude-opus-5-5", "medium", &1),
          [{"FAKE_EXIT", "1"}]
        )

      assert {:error, {:provider_session_unavailable, tail}} = result
      assert tail =~ "No conversation found"
    end

    test "other failures are provider_failure with the observed session",
         %{dir: dir, context: context} do
      stream!(dir, [init(), result(%{"subtype" => "error_during_execution", "is_error" => true})])
      uuid = Claude.uuid4()

      assert {:error, {:provider_failure, {:provider_error, _}, %{provider_session_id: ^uuid}}} =
               Harness.shaping_turn(
                 {:fresh, uuid},
                 "p",
                 "claude-opus-5-5",
                 "medium",
                 shaping_context(dir, context)
               )
    end

    test "the hard timeout reports timeout, not a settled turn", %{dir: dir, context: context} do
      sleeper = Path.join(dir, "sleepy")
      File.write!(sleeper, "#!/bin/sh\ncat > /dev/null\nsleep 30\n")
      File.chmod!(sleeper, 0o755)
      context = shaping_context(dir, %{context | executable: sleeper}, %{timeout_ms: 300})

      assert {:error, {:timeout, %{provider_session_id: nil}}} =
               Harness.shaping_turn({:fresh, Claude.uuid4()}, "p", "m", "medium", context)
    end

    test "a fresh turn without a UUID is rejected", %{dir: dir, context: context} do
      assert_raise ArgumentError, fn ->
        Harness.shaping_turn({:fresh, nil}, "p", "m", "medium", shaping_context(dir, context))
      end
    end
  end

  describe "launch environment" do
    test "every role launch overrides an inherited substitution-rm prompt setting with 1",
         %{dir: dir, context: context} do
      launches = [
        {[init(), root("claude-opus-5-5", []), result(%{"result" => @notes})],
         &Harness.launch_build_developer("p", "claude-opus-5-5", "medium", [], &1)},
        {[init(), result(%{"result" => @notes})],
         &Harness.resume_build_developer("abc-123", "f", "claude-opus-5-5", "medium", [], &1)},
        {[init(), result(%{"structured_output" => @verdict, "result" => ""})],
         &Harness.launch_reviewer("r", "claude-opus-5-5", "medium", &1)},
        {[init(), result(%{})],
         &Harness.shaping_turn(
           {:fresh, Claude.uuid4()},
           "p",
           "claude-opus-5-5",
           "medium",
           Map.put(&1, :log_path, Path.join(dir, "turns/env.jsonl"))
         )}
      ]

      for {events, launch} <- launches do
        stream!(dir, events)
        File.rm_rf!(Path.join(dir, "env"))

        result = run(context, launch, [{"CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT", "0"}])
        assert result == 0 or match?({:ok, _}, result)

        env = File.read!(Path.join(dir, "env"))
        assert env =~ "CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT=1\n"
        refute env =~ "CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT=0"
      end
    end
  end

  describe "role write boundary" do
    @describetag :unconfined

    @boundary_role_script """
    #!/bin/sh
    write_result() {
      label="$1"; path="$2"
      msg=$( (echo hi > "$path") 2>&1 )
      status=$?
      printf '%s|%s|%s\\n' "$label" "$status" "$msg" >> "$RECEIPT_PATH"
    }

    write_result inside_candidate "$CANDIDATE_DIR/inside-candidate.txt"
    write_result inside_harness_home "$HARNESS_HOME_DIR/inside-harness-home.txt"
    write_result inside_tmp "$TMPDIR/inside-tmp.txt"
    write_result outside_control "$CONTROL_DIR/outside-control.txt"
    write_result outside_sentinel "$SENTINEL_DIR/outside-sentinel.txt"

    nested_out=$(/usr/bin/sandbox-exec -p '(version 1)(allow default)' /usr/bin/true 2>&1)
    nested_status=$?
    printf 'nested_sandbox|%s|%s\\n' "$nested_status" "$nested_out" >> "$RECEIPT_PATH"

    cat > /dev/null

    session=; previous=
    for a in "$@"; do
      [ "$previous" = --session-id ] && session="$a"
      [ "$previous" = --resume ] && session="$a"
      previous="$a"
    done

    printf '{"type":"system","subtype":"init","session_id":"%s"}\\n' "$session"
    printf '{"type":"assistant","session_id":"%s","parent_tool_use_id":null,"message":{"model":"claude-opus-5-5","content":[]}}\\n' "$session"
    printf '{"type":"result","subtype":"success","is_error":false,"session_id":"%s","result":"done"}\\n' "$session"
    """

    setup do
      base =
        Path.join(
          System.tmp_dir!(),
          "kogen-write-boundary-#{System.pid()}-#{System.unique_integer([:positive])}"
        )

      candidate = Path.join(base, "candidate")
      harness_home = Path.join(base, "harness-home")
      tmp_dir = Path.join(base, "tmp")
      control = Path.join(base, "control")
      sentinel = Path.join(base, "sentinel")

      Enum.each([candidate, harness_home, tmp_dir, control, sentinel], &File.mkdir_p!/1)
      on_exit(fn -> File.rm_rf!(base) end)

      executable = Path.join(base, "claude")
      File.write!(executable, @boundary_role_script)
      File.chmod!(executable, 0o755)

      assert {:ok, boundary} =
               WriteBoundary.prepare(%{
                 candidate: candidate,
                 harness_home: harness_home,
                 tmp_dir: tmp_dir,
                 control: control
               })

      %{
        base: base,
        candidate: candidate,
        harness_home: harness_home,
        tmp_dir: tmp_dir,
        control: control,
        sentinel: sentinel,
        executable: executable,
        boundary: boundary
      }
    end

    defp boundary_context(fixture, receipt_path, prefix) do
      %{
        harness: "claude",
        executable: fixture.executable,
        args: [],
        env: [
          {"CANDIDATE_DIR", fixture.candidate},
          {"HARNESS_HOME_DIR", fixture.harness_home},
          {"TMPDIR", fixture.tmp_dir},
          {"CONTROL_DIR", fixture.control},
          {"SENTINEL_DIR", fixture.sentinel},
          {"RECEIPT_PATH", receipt_path}
        ],
        config: @config,
        project: fixture.candidate,
        cwd: fixture.candidate,
        prefix: prefix
      }
    end

    defp receipt_lines(path) do
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        [label, status, message] = String.split(line, "|", parts: 3)
        {label, {String.to_integer(status), message}}
      end)
    end

    test "a fake role's writes are confined to the Candidate, harness home and Build temp dir, and a nested sandbox-exec reports confinement",
         %{} = fixture do
      receipt = Path.join(fixture.harness_home, "receipt.txt")

      prefix = WriteBoundary.prefix(fixture.boundary)
      context = boundary_context(fixture, receipt, prefix)

      assert {:ok, turn} =
               Claude.launch_build_developer(
                 "PROMPT",
                 "claude-opus-5-5",
                 "medium",
                 [],
                 context
               )

      assert turn.message == "done"

      results = receipt_lines(receipt)
      assert {0, _} = results["inside_candidate"]
      assert {0, _} = results["inside_harness_home"]
      assert {0, _} = results["inside_tmp"]

      assert {status, message} = results["outside_control"]
      assert status != 0
      assert message =~ "Operation not permitted"
      refute File.exists?(Path.join(fixture.control, "outside-control.txt"))

      assert {status, message} = results["outside_sentinel"]
      assert status != 0
      assert message =~ "Operation not permitted"
      refute File.exists?(Path.join(fixture.sentinel, "outside-sentinel.txt"))

      assert {71, _} = results["nested_sandbox"]
    end

    test "a control launch without the boundary prefix lets the same outside write through",
         %{} = fixture do
      receipt = Path.join(fixture.harness_home, "control-receipt.txt")
      context = boundary_context(fixture, receipt, [])

      assert {:ok, turn} =
               Claude.launch_build_developer(
                 "PROMPT",
                 "claude-opus-5-5",
                 "medium",
                 [],
                 context
               )

      assert turn.message == "done"

      results = receipt_lines(receipt)
      assert {0, _} = results["outside_control"]
      assert File.read!(Path.join(fixture.control, "outside-control.txt")) == "hi\n"
      assert {0, _} = results["outside_sentinel"]
    end
  end

  defp sha(value), do: Base.encode16(:crypto.hash(:sha256, value), case: :lower)
end
