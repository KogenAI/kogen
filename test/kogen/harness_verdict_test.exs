defmodule Kogen.HarnessVerdictTest do
  use Kogen.IsolatedCase, async: true

  test "Reviewer returns the strict wire response and rejects malformed structures" do
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

    valid = valid_verdict()
    System.put_env("REVIEWER_VERDICT", Jason.encode!(valid))

    assert {:ok,
            %{
              session_id: "review",
              verdict: "accept",
              findings: [],
              response: ^valid
            }} = Kogen.Harness.launch_reviewer("test", "fake", "low")

    System.delete_env("KOGEN_RAW_LOG_DIR")

    for malformed <- [
          Map.delete(valid, "candidate_id"),
          put_in(valid, ["scenarios", Access.at(0), "status"], "unknown"),
          put_in(valid, ["dispositions", Access.at(0), "evidence"], [%{"path" => "test.exs"}]),
          %{"verdict" => "accept", "findings" => []}
        ] do
      System.put_env("REVIEWER_VERDICT", Jason.encode!(malformed))

      assert {:error, {:malformed_verdict, 0, details}} =
               Kogen.Harness.launch_reviewer("test", "fake", "low")

      assert details["reviewer_session_id"] == "review"
      assert Jason.decode!(details["message"]) == malformed
    end
  end

  test "Developer keeps its settled session when the final agent message is absent" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "kogen developer message #{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    executable = Path.join(dir, "provider")
    previous = System.get_env("KOGEN_HARNESS")

    on_exit(fn ->
      if previous,
        do: System.put_env("KOGEN_HARNESS", previous),
        else: System.delete_env("KOGEN_HARNESS")

      File.rm_rf!(dir)
    end)

    File.write!(executable, """
    #!/bin/sh
    cat >/dev/null || true
    printf '%s\\n' '{"type":"thread.started","thread_id":"developer"}' '{"type":"item.completed","item":{"type":"agent_message","text":"current handoff"}}' '{"type":"turn.completed","thread_id":"developer"}'
    """)

    File.chmod!(executable, 0o755)
    System.put_env("KOGEN_HARNESS", executable)

    assert {:ok, %{session_id: "developer", message: "current handoff", result: result}} =
             Kogen.Harness.launch_developer("test", "fake", "low")

    assert result["type"] == "turn.completed"

    File.write!(executable, """
    #!/bin/sh
    cat >/dev/null || true
    printf '%s\\n' '{"type":"thread.started","thread_id":"developer"}' '{"type":"turn.completed","thread_id":"developer"}'
    """)

    File.chmod!(executable, 0o755)

    assert {:ok, %{session_id: "developer", message: ""}} =
             Kogen.Harness.launch_developer("test", "fake", "low")
  end

  defp valid_verdict do
    %{
      "candidate_id" => "candidate-1",
      "attempt_token" => "attempt-1",
      "verdict" => "accept",
      "scenarios" => [
        %{
          "id" => "scenario-1",
          "status" => "satisfied",
          "reason" => "The implementation meets the scenario.",
          "evidence" => [%{"path" => "lib/kogen/harness.ex", "locator" => "line 1"}]
        }
      ],
      "dispositions" => [
        %{
          "id" => "finding-1",
          "status" => "closed",
          "reason" => "The inspected implementation fixes it.",
          "evidence" => [
            %{"path" => "test/kogen/harness_verdict_test.exs", "locator" => "line 1"}
          ]
        }
      ],
      "findings" => []
    }
  end
end
