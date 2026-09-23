defmodule Kogen.HarnessRoleTest do
  use Kogen.IsolatedCase, async: true

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
