defmodule Kogen.ClaudeCodeHarnessTest do
  @moduledoc """
  The Claude Code adapter behind `Kogen.Harness`, driven with a scripted fake
  `claude` that records argv, environment and stdin and replays a stream-json
  capture. No provider is contacted.
  """
  use Kogen.IsolatedCase, async: true

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

      settings = args |> flag("--settings") |> File.read!() |> Jason.decode!()
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

      for role <- ["reviewer", "shaper"],
          {_name, agent} <- Claude.agents(role, @config.helpers) do
        assert Enum.all?(agent["tools"], &(&1 not in ~w(Edit Write NotebookEdit Agent)))
      end

      for role <- ["developer", "reviewer", "shaper"] do
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

      assert Claude.disallowed_tools("shaper") == Claude.disallowed_tools("developer")
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

  describe "Shaper" do
    test "the interactive Shaper receives the prompt as its first message", %{
      dir: dir,
      context: context
    } do
      prompt = Path.join(dir, "prompt.md")
      File.write!(prompt, "Shape one Intent.")
      stream!(dir, [])

      assert 0 == Harness.exec_shaper("claude-opus-5-5", "medium", prompt, context)
      args = argv(dir)
      refute "-p" in args
      refute "--output-format" in args
      assert Enum.take(args, -2) == ["--", "Shape one Intent."]
      assert flag(args, "--model") == "claude-opus-5-5"
      assert flag(args, "--effort") == "medium"
      assert "--dangerously-skip-permissions" in args
      assert File.read!(Path.join(dir, "env")) =~ "KOGEN_ROLE=shaper"
    end
  end

  describe "launch environment" do
    test "every role launch overrides an inherited substitution-rm prompt setting with 1",
         %{dir: dir, context: context} do
      prompt = Path.join(dir, "prompt.md")
      File.write!(prompt, "Shape one Intent.")

      launches = [
        {[init(), root("claude-opus-5-5", []), result(%{"result" => @notes})],
         &Harness.launch_build_developer("p", "claude-opus-5-5", "medium", [], &1)},
        {[init(), result(%{"result" => @notes})],
         &Harness.resume_build_developer("abc-123", "f", "claude-opus-5-5", "medium", [], &1)},
        {[init(), result(%{"structured_output" => @verdict, "result" => ""})],
         &Harness.launch_reviewer("r", "claude-opus-5-5", "medium", &1)},
        {[], &Harness.exec_shaper("claude-opus-5-5", "medium", prompt, &1)}
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

  defp sha(value), do: Base.encode16(:crypto.hash(:sha256, value), case: :lower)
end
