defmodule Kogen.HarnessRoleTest do
  use Kogen.IsolatedCase, async: true

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
      reviewer) cat >/dev/null || true; printf '%s\\n' '{"verdict":"accept","findings":[]}' > "$out"; printf '%s\\n' '{"type":"thread.started","thread_id":"review"}' '{"type":"turn.completed","thread_id":"review"}' ;;
      shaper) [ "$KOGEN_REQUIRE_TTY" != 1 ] || test -t 0 ;;
    esac
    """)

    File.chmod!(executable, 0o755)
    System.put_env("KOGEN_HARNESS", executable)
    System.put_env("ROLE_LOG", log)
    System.put_env("KOGEN_RAW_LOG_DIR", raw_log_dir)
    System.put_env("KOGEN_ROLE", "reviewer")
    assert {:ok, _} = Kogen.Harness.launch_developer("test", "fake", "low")
    assert {:ok, _} = Kogen.Harness.resume_developer("dev", "test", "fake", "low")
    System.put_env("KOGEN_ROLE", "developer")
    assert {:ok, _} = Kogen.Harness.launch_reviewer("test", "fake", "low")
    assert [verdict_path] = Path.wildcard(Path.join(raw_log_dir, "reviewer-verdict-*.json"))
    assert File.read!(verdict_path) == "{\"verdict\":\"accept\",\"findings\":[]}\n"

    assert File.read!(Path.join(raw_log_dir, "reviewer-verdicts.jsonl")) ==
             "{\"findings\":[],\"session_id\":\"review\",\"verdict\":\"accept\"}\n"

    prompt = Path.join(dir, "prompt")
    File.write!(prompt, "shape")
    probe = Path.expand("../support/terminal_probe.py", __DIR__)
    elixir = System.find_executable("elixir") || raise "elixir executable not found"

    code_paths =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.flat_map(&["-pa", &1])

    expression =
      "System.halt(Kogen.Harness.exec_shaper(\"fake\", \"low\", #{inspect(prompt)}))"

    for mode <- ["pipe", "pty"] do
      assert {"", 0} =
               System.cmd(
                 "python3",
                 [
                   probe,
                   "--mode",
                   mode,
                   "--",
                   elixir,
                   "--erl",
                   "+S 2:2 +SDcpu 1 +SDio 1" | code_paths
                 ] ++
                   [
                     "-e",
                     expression
                   ],
                 env: [
                   {"KOGEN_HARNESS", executable},
                   {"ROLE_LOG", log},
                   {"KOGEN_REQUIRE_TTY", if(mode == "pty", do: "1", else: "0")}
                 ],
                 stderr_to_stdout: true
               )
    end

    assert File.read!(log) == "developer\ndeveloper\nreviewer\nshaper\nshaper\n"
  end
end
