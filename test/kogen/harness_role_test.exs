defmodule Kogen.HarnessRoleTest do
  use ExUnit.Case, async: false

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
    cat >/dev/null || true
    out=; prev=
    for a in "$@"; do [ "$prev" = --output-last-message ] && out="$a"; prev="$a"; done
    case "$KOGEN_ROLE" in
      developer) printf '%s\\n' '{"type":"thread.started","thread_id":"dev"}' '{"type":"turn.completed","thread_id":"dev"}' ;;
      reviewer) printf '%s\\n' '{"verdict":"accept","findings":[]}' > "$out"; printf '%s\\n' '{"type":"thread.started","thread_id":"review"}' '{"type":"turn.completed","thread_id":"review"}' ;;
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
    prompt = Path.join(dir, "prompt")
    File.write!(prompt, "shape")
    assert 0 == Kogen.Harness.exec_shaper("fake", "low", prompt)
    assert File.read!(log) == "developer\ndeveloper\nreviewer\nshaper\n"

    assert [verdict_path] = Path.wildcard(Path.join(raw_log_dir, "reviewer-verdict-*.json"))
    assert File.read!(verdict_path) == "{\"verdict\":\"accept\",\"findings\":[]}\n"

    assert File.read!(Path.join(raw_log_dir, "reviewer-verdicts.jsonl")) ==
             "{\"findings\":[],\"session_id\":\"review\",\"verdict\":\"accept\"}\n"
  end
end
