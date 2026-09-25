defmodule Kogen.HarnessRoleTest do
  use Kogen.IsolatedCase, async: true

  alias Kogen.Harness.Claude
  alias Mix.Tasks.Kogen.Expert

  @moduletag timeout: 120_000

  test "every Codex launch overrides a hostile inherited role" do
    dir = Path.join(System.tmp_dir!(), "kogen roles-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    executable = Path.join(dir, "provider")
    log = Path.join(dir, "roles")
    raw_log_dir = Path.join(dir, "raw-streams")

    original =
      Map.new(["KOGEN_ROLE", "KOGEN_HARNESS", "ROLE_LOG", "KOGEN_RAW_LOG_DIR"], fn key ->
        {key, System.get_env(key)}
      end)

    on_exit(fn ->
      Enum.each(original, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)

      File.rm_rf!(dir)
    end)

    File.write!(executable, """
    #!/bin/sh
    printf '%s\\n' "$KOGEN_ROLE" >> "$ROLE_LOG"
    out=; prev=
    for a in "$@"; do [ "$prev" = --output-last-message ] && out="$a"; prev="$a"; done
    case "$KOGEN_ROLE" in
      developer) cat >/dev/null || true; printf '%s\\n' '{"type":"thread.started","thread_id":"dev"}' '{"type":"turn.completed","thread_id":"dev"}' ;;
      reviewer) cat >/dev/null || true; printf '%s\\n' '{"candidate_id":"fixture-candidate","attempt_token":"fixture-attempt","verdict":"accept","scenarios":[],"dispositions":[],"findings":[]}' > "$out"; printf '%s\\n' '{"type":"thread.started","thread_id":"review"}' '{"type":"turn.completed","thread_id":"review"}' ;;
      shaper)
        [ "$KOGEN_REQUIRE_TTY" != 1 ] || test -t 0 || exit 31
        case "${KOGEN_SHAPER_BEHAVIOR:-success}" in
          early) exit 23 ;;
          missing) sleep 60 ;;
        esac
        sleep "${KOGEN_START_DELAY:-0}"
        : > "$KOGEN_READY_MARKER"
        case "${KOGEN_SHAPER_BEHAVIOR:-success}" in
          eof) cat >/dev/null ;;
          background-success)
            python3 -c 'import os, subprocess; p = subprocess.Popen(["sleep", "60"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, close_fds=True); open(os.environ["KOGEN_DESCENDANT_PID"], "w").write(str(p.pid))'
            sleep 0.5
            ;;
          background-failure)
            python3 -c 'import os, subprocess; p = subprocess.Popen(["sleep", "60"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, close_fds=True); open(os.environ["KOGEN_DESCENDANT_PID"], "w").write(str(p.pid))'
            sleep 0.5
            exit 29
            ;;
        esac
        ;;
    esac
    """)

    File.chmod!(executable, 0o755)
    System.put_env("KOGEN_HARNESS", executable)
    System.put_env("ROLE_LOG", log)
    System.put_env("KOGEN_RAW_LOG_DIR", raw_log_dir)
    System.put_env("KOGEN_ROLE", "reviewer")
    context = %{harness: "codex", executable: executable, args: [], env: []}
    assert {:ok, _} = Kogen.Harness.launch_developer("test", "fake", "low", [], context)
    assert {:ok, _} = Kogen.Harness.resume_developer("dev", "test", "fake", "low", [], context)
    System.put_env("KOGEN_ROLE", "developer")
    assert {:ok, _} = Kogen.Harness.launch_reviewer("test", "fake", "low", context)
    assert [verdict_path] = Path.wildcard(Path.join(raw_log_dir, "reviewer-verdict-*.json"))

    assert File.read!(verdict_path) ==
             "{\"candidate_id\":\"fixture-candidate\",\"attempt_token\":\"fixture-attempt\",\"verdict\":\"accept\",\"scenarios\":[],\"dispositions\":[],\"findings\":[]}\n"

    assert File.read!(Path.join(raw_log_dir, "reviewer-verdicts.jsonl")) ==
             "{\"attempt_token\":\"fixture-attempt\",\"candidate_id\":\"fixture-candidate\",\"dispositions\":[],\"findings\":[],\"scenarios\":[],\"session_id\":\"review\",\"verdict\":\"accept\"}\n"

    prompt = Path.join(dir, "prompt")
    File.write!(prompt, "shape")
    probe = Path.expand("../support/terminal_probe.py", __DIR__)
    elixir = System.find_executable("elixir") || raise "elixir executable not found"

    code_paths =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.flat_map(&["-pa", &1])

    shaper_context = %{harness: "codex", executable: executable, args: [], env: []}

    expression =
      "System.halt(Kogen.Harness.exec_shaper(\"fake\", \"low\", #{inspect(prompt)}, #{inspect(shaper_context)}))"

    command = [elixir, "--erl", "+S 2:2 +SDcpu 1 +SDio 1"] ++ code_paths ++ ["-e", expression]

    for mode <- ["pipe", "pty"], behavior <- terminal_behaviors() do
      {output, status, pid_path} =
        run_shaper_probe(probe, command, executable, log, dir, mode, behavior)

      assert_terminal_outcome(behavior, "#{mode} #{behavior}: #{output}", status)

      if pid_path do
        pid = pid_path |> File.read!() |> String.trim()
        assert {_, kill_status} = System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true)
        assert kill_status != 0, "#{mode} #{behavior} descendant #{pid} survived cleanup"
      end
    end

    roles = log |> File.read!() |> String.split("\n", trim: true)
    assert Enum.take(roles, 3) == ["developer", "developer", "reviewer"]
    assert Enum.count(roles, &(&1 == "shaper")) == 12
  end

  @hybrid_config """
  default_route: hybrid
  routes:
    hybrid:
      shaping:   {harness: claude, model: claude-opus-5-5, effort: medium}
      developer: {harness: claude, model: claude-opus-5-5, effort: medium}
      reviewer:  {harness: codex, model: gpt-6-sol, effort: high}
      expert:    {harness: codex, model: gpt-6-sol, effort: high}
      helpers:
        claude:
          scout:  {model: claude-sonnet-5, effort: low}
          worker: {model: claude-sonnet-5, effort: medium}
        codex:
          scout:  {model: gpt-6-luna, effort: low}
          worker: {model: gpt-6-luna, effort: high}
  outer_resumptions: 2
  verification_retries: 2
  """

  # Claude Code speaks `-p` stream-json and Codex speaks `exec` JSONL; one
  # offline executable answers either protocol and logs argv and role env.
  @dual_protocol """
  #!/bin/sh
  printf 'argv:' >> "$DISPATCH_LOG"; for a in "$@"; do printf ' %s' "$a" >> "$DISPATCH_LOG"; done
  printf '\\nenv: KOGEN_ROLE=%s KOGEN_EXPERT=%s KOGEN_VERIFICATION_CONTEXT=%s\\n' "${KOGEN_ROLE:-}" "${KOGEN_EXPERT:-unset}" "${KOGEN_VERIFICATION_CONTEXT:-unset}" >> "$DISPATCH_LOG"
  if [ "${1:-}" = auth ]; then
    printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}'
    exit 0
  fi
  cat > /dev/null
  protocol=
  for a in "$@"; do
    case "$a" in -p|exec) protocol="$a"; break ;; esac
  done
  if [ "$protocol" = exec ]; then
    printf '%s\\n' '{"type":"thread.started","thread_id":"codex-expert"}' '{"type":"item.completed","item":{"type":"agent_message","text":"codex expert answer"}}' '{"type":"turn.completed"}'
    exit 0
  fi
  sid=; model=; prev=
  for a in "$@"; do
    [ "$prev" = --session-id ] && sid="$a"
    [ "$prev" = --model ] && model="$a"
    prev="$a"
  done
  printf '{"type":"system","subtype":"init","session_id":"%s"}\\n' "$sid"
  printf '{"type":"assistant","session_id":"%s","message":{"model":"%s","content":[]}}\\n' "$sid" "${FAKE_ROOT_MODEL:-$model}"
  printf '{"type":"result","subtype":"success","is_error":false,"result":"claude expert answer","session_id":"%s"}\\n' "$sid"
  """

  test "a hybrid route launches each role only through its assigned harness and profile" do
    dir = Path.join(System.tmp_dir!(), "kogen-hybrid-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    executable = Path.join(dir, "provider")
    log = Path.join(dir, "dispatch")
    File.write!(executable, @dual_protocol)
    File.chmod!(executable, 0o755)
    config_path = Path.join(dir, "config.yaml")
    File.write!(config_path, @hybrid_config)
    System.put_env("KOGEN_HARNESS", executable)
    System.put_env("DISPATCH_LOG", log)
    private_claude_scope!(dir)
    System.delete_env("KOGEN_RAW_LOG_DIR")
    # An inherited Developer verification context must never reach an Expert.
    System.put_env("KOGEN_VERIFICATION_CONTEXT", "/inherited/context")

    {:ok, config} = Kogen.Intent.read_config(config_path)

    assert {:ok, runtime} =
             Kogen.Harness.open_roles(config, [:developer, :reviewer, :expert], dir)

    assert runtime.selections |> Map.keys() |> Enum.sort() == ["claude", "codex"]

    developer = Kogen.Harness.role_context(runtime, :developer)
    reviewer = Kogen.Harness.role_context(runtime, :reviewer)
    assert developer.harness == "claude"
    assert reviewer.harness == "codex"

    # The dominant Developer carries the frozen Codex Expert assignment; its
    # native Claude Code helpers exclude any substituted expert.
    {"KOGEN_EXPERT", json} = List.keyfind(developer.env, "KOGEN_EXPERT", 0)

    assert Jason.decode!(json) == %{
             "route" => "hybrid",
             "caller" => "developer",
             "harness" => "codex",
             "model" => "gpt-6-sol",
             "effort" => "high",
             "helpers" => %{
               "scout" => %{"model" => "gpt-6-luna", "effort" => "low"},
               "worker" => %{"model" => "gpt-6-luna", "effort" => "high"}
             }
           }

    assert List.keyfind(reviewer.env, "KOGEN_EXPERT", 0) == {"KOGEN_EXPERT", nil}

    developer_args =
      Claude.developer_args("claude-opus-5-5", "medium", developer, {:fresh, "s"})

    agents = developer_args |> after_flag("--agents") |> Jason.decode!()
    assert agents |> Map.keys() |> Enum.sort() == ["kogen-scout", "kogen-worker"]
    assert agents["kogen-scout"]["model"] == "claude-sonnet-5"
    assert "--dangerously-skip-permissions" in developer_args
    assert after_flag(developer_args, "--model") == "claude-opus-5-5"
    assert after_flag(developer_args, "--effort") == "medium"

    # The Expert role itself launches on Codex with Codex's unattended flags.
    assignment = Expert.assignment(json)
    assert {:ok, %{harness: "codex", expert: %{model: "gpt-6-sol", effort: "high"}}} = assignment
    {:ok, expert_config} = assignment

    assert {:ok, %{session_id: "codex-expert", message: "codex expert answer"}} =
             Expert.launch(expert_config, "Which lock order is safe?", dir)

    assert_raise ArgumentError, ~r/role shaping was not opened/, fn ->
      Kogen.Harness.role_context(runtime, :shaping)
    end

    Kogen.Harness.close(runtime)

    # The codex-dominant route's Expert runs on Claude Code, read-only, with
    # only Claude Code native helpers and no nested expert.
    claude_expert = %{
      route: "hybrid",
      caller: "developer",
      harness: "claude",
      expert: %{model: "claude-opus-5-5", effort: "high"},
      helpers: %{
        scout: %{model: "claude-sonnet-5", effort: "low"},
        worker: %{model: "claude-sonnet-5", effort: "medium"}
      },
      roles: %{expert: "claude"},
      native_helpers: %{
        "claude" => %{
          scout: %{model: "claude-sonnet-5", effort: "low"},
          worker: %{model: "claude-sonnet-5", effort: "medium"}
        }
      }
    }

    {:ok, claude_selection} = Kogen.Harness.open(claude_expert, dir)
    claude_context = Kogen.Harness.launch_context(claude_selection)

    assert {:ok, %{message: "claude expert answer"}} =
             Kogen.Harness.launch_expert("question", "claude-opus-5-5", "high", claude_context)

    # A provider answering from another model is a failure, never a fallback.
    System.put_env("FAKE_ROOT_MODEL", "claude-sonnet-5")

    assert {:error,
            {:root_model_mismatch, %{expected: "claude-opus-5-5", actual: "claude-sonnet-5"}}} =
             Kogen.Harness.launch_expert("question", "claude-opus-5-5", "high", claude_context)

    entries = log |> File.read!() |> String.split("argv:", trim: true)
    [codex_expert] = Enum.filter(entries, &String.starts_with?(&1, " exec "))
    claude_launch = Enum.find(entries, &String.starts_with?(&1, " -p "))

    assert codex_expert =~
             ~s(exec --model gpt-6-sol -c model_reasoning_effort="high" --enable hooks --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox --json -)

    assert codex_expert =~ "KOGEN_ROLE=expert KOGEN_EXPERT=unset KOGEN_VERIFICATION_CONTEXT=unset"

    assert claude_launch =~ "--model claude-opus-5-5 --effort high --dangerously-skip-permissions"
    assert claude_launch =~ "Agent(general-purpose)"
    assert claude_launch =~ " Edit Write NotebookEdit "
    assert claude_launch =~ "kogen-scout"
    refute claude_launch =~ "kogen-expert"

    assert claude_launch =~
             "KOGEN_ROLE=expert KOGEN_EXPERT=unset KOGEN_VERIFICATION_CONTEXT=unset"
  end

  # Expert launches reuse the prepared launch context: its arguments (which
  # carry the central tool_output_token_limit, see codex_environment_test)
  # and environment precede the role's own flags.
  test "Codex Expert launches run from the prepared launch context" do
    dir = Path.join(System.tmp_dir!(), "kogen-prepared-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    executable = Path.join(dir, "provider")
    log = Path.join(dir, "dispatch")
    File.write!(executable, @dual_protocol)
    File.chmod!(executable, 0o755)
    System.put_env("DISPATCH_LOG", log)
    System.put_env("KOGEN_EXPERT", ~s({"inherited":true}))
    System.put_env("KOGEN_VERIFICATION_CONTEXT", "/inherited/context")

    prepared = ["--disable", "apps", "-c", "tool_output_token_limit=4000"]

    context = %{
      harness: "codex",
      executable: executable,
      args: prepared,
      env: [{"DISPATCH_LOG", log}]
    }

    assert {:ok, %{session_id: "codex-expert"}} =
             Kogen.Harness.launch_expert("q", "gpt-6-sol", "high", context)

    [expert] = log |> File.read!() |> String.split("argv:", trim: true)

    assert expert =~
             ~s( --disable apps -c tool_output_token_limit=4000 exec --model gpt-6-sol -c model_reasoning_effort="high" --enable hooks --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox --json -)

    assert expert =~
             "KOGEN_ROLE=expert KOGEN_EXPERT=unset KOGEN_VERIFICATION_CONTEXT=unset"
  end

  test "a harness that is not ready names its roles and releases held selections" do
    dir = Path.join(System.tmp_dir!(), "kogen-unready-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    executable = Path.join(dir, "provider")
    File.write!(executable, @dual_protocol)
    File.chmod!(executable, 0o755)
    System.put_env("KOGEN_HARNESS", executable)
    System.put_env("DISPATCH_LOG", Path.join(dir, "dispatch"))
    private_claude_scope!(dir)

    {:ok, config} =
      Kogen.Intent.read_config(".kogen/config.yaml", "claude-dominant-adversarial-codex")

    broken = put_in(config, [:roles, :reviewer], "pi")

    assert {:error,
            "reviewer harness pi is not ready: unsupported harness: \"pi\"; expected codex or claude"} =
             Kogen.Harness.open_roles(broken, [:developer, :reviewer, :expert])

    assert {:error, reason} = Expert.assignment(nil)
    assert reason =~ "missing KOGEN_EXPERT assignment"
    assert {:error, reason} = Expert.assignment(~s({"harness":"pi"}))
    assert reason =~ "invalid KOGEN_EXPERT assignment"
  end

  test "no harness exposes an auditor launch" do
    Code.ensure_loaded(Kogen.Harness)
    Code.ensure_loaded(Kogen.Harness.Claude)
    Code.ensure_loaded(Kogen.Harness.Codex)

    refute function_exported?(Kogen.Harness, :launch_auditor, 4)
    refute function_exported?(Kogen.Harness.Claude, :launch_auditor, 4)
    refute function_exported?(Kogen.Harness.Codex, :launch_auditor, 4)

    assert Kogen.Intent.roles() == [:shaping, :developer, :reviewer, :expert]
    config = %{harness: "claude"}

    assert_raise ArgumentError, ~r/unknown role :auditor/, fn ->
      Kogen.Harness.open_roles(config, [:auditor])
    end

    assert_raise ArgumentError, ~r/unknown role :auditor/, fn ->
      Kogen.Intent.role_config(config, :auditor)
    end
  end

  defp private_claude_scope!(dir) do
    root = Path.join(dir, "claude-root")
    File.mkdir_p!(Path.join(root, "accounts/shared"))
    System.put_env("KOGEN_CLAUDE_ROOT", root)
  end

  defp after_flag(args, flag) do
    index = Enum.find_index(args, &(&1 == flag))
    Enum.at(args, index + 1)
  end

  defp terminal_behaviors do
    [:success, :eof, :early, :missing, :background_success, :background_failure]
  end

  defp run_shaper_probe(probe, command, executable, log, dir, mode, behavior) do
    marker = Path.join(dir, "ready-#{mode}-#{behavior}")

    pid_path =
      if behavior in [:background_success, :background_failure],
        do: Path.join(dir, "descendant-#{mode}-#{behavior}.pid")

    startup_timeout = if behavior == :missing, do: "5", else: "15"
    completion_timeout = if behavior == :eof, do: "0.3", else: "5"

    ownership_args = if pid_path, do: ["--owned-pid-file", pid_path], else: []

    {output, status} =
      System.cmd(
        "python3",
        [
          probe,
          "--mode",
          mode,
          "--startup-timeout",
          startup_timeout,
          "--timeout",
          completion_timeout,
          "--ready-marker",
          marker
        ] ++ ownership_args ++ ["--" | command],
        env: [
          {"KOGEN_HARNESS", executable},
          {"ROLE_LOG", log},
          {"KOGEN_START_DELAY", "0.1"},
          {"KOGEN_SHAPER_BEHAVIOR", behavior |> Atom.to_string() |> String.replace("_", "-")},
          {"KOGEN_DESCENDANT_PID", pid_path},
          {"KOGEN_REQUIRE_TTY", if(mode == "pty", do: "1", else: "0")}
        ],
        stderr_to_stdout: true
      )

    {output, status, pid_path}
  end

  defp assert_terminal_outcome(:success, output, status) do
    assert status == 0, output
  end

  defp assert_terminal_outcome(:eof, output, status) do
    assert status == 1
    assert output =~ "did not complete after readiness deadline"
  end

  defp assert_terminal_outcome(:early, output, status) do
    assert status == 1
    assert output =~ "exited before readiness (status 23)"
  end

  defp assert_terminal_outcome(:missing, output, status) do
    assert status == 1
    assert output =~ "did not become ready before startup deadline"
  end

  defp assert_terminal_outcome(:background_success, output, status) do
    assert status == 0, output
  end

  defp assert_terminal_outcome(:background_failure, output, status) do
    assert status == 1
    assert output =~ "command exited with status 29"
  end
end
