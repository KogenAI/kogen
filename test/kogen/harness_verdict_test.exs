defmodule Kogen.HarnessVerdictTest do
  use ExUnit.Case, async: false

  test "Reviewer rejects rework without actionable findings and blank findings" do
    dir =
      Path.join(System.tmp_dir!(), "kogen reviewer verdict #{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    executable = Path.join(dir, "provider")

    original =
      Map.new(
        ["KOGEN_HARNESS", "KOGEN_RAW_LOG_DIR", "REVIEWER_VERDICT"],
        &{&1, System.get_env(&1)}
      )

    on_exit(fn ->
      Enum.each(original, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)

      File.rm_rf!(dir)
    end)

    File.write!(executable, """
    #!/bin/sh
    cat >/dev/null || true
    out=; prev=
    for arg in "$@"; do [ "$prev" = --output-last-message ] && out="$arg"; prev="$arg"; done
    printf '%s\\n' "$REVIEWER_VERDICT" > "$out"
    printf '%s\\n' '{"type":"thread.started","thread_id":"review"}' '{"type":"turn.completed","thread_id":"review"}'
    """)

    File.chmod!(executable, 0o755)
    System.put_env("KOGEN_HARNESS", executable)
    System.put_env("KOGEN_RAW_LOG_DIR", Path.join(dir, "raw-streams"))

    for verdict <- [
          "{\"verdict\":\"rework\",\"findings\":[]}",
          "{\"verdict\":\"rework\",\"findings\":[\"  \"]}",
          "{\"verdict\":\"accept\",\"findings\":[\"\\t\"]}"
        ] do
      System.put_env("REVIEWER_VERDICT", verdict)

      assert {:error, {:malformed_verdict, 0, _output}} =
               Kogen.Harness.launch_reviewer("test", "fake", "low")
    end
  end
end
