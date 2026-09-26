defmodule Kogen.HarnessVerdictTest do
  use Kogen.IsolatedCase, async: true

  alias Kogen.Harness.Verdict

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
    context = %{harness: "codex", executable: executable, args: [], env: []}

    valid = valid_verdict()
    System.put_env("REVIEWER_VERDICT", Jason.encode!(valid))

    assert {:ok,
            %{
              session_id: "review",
              verdict: "accept",
              findings: [],
              response: ^valid
            }} = Kogen.Harness.launch_reviewer("test", "fake", "low", context)

    System.delete_env("KOGEN_RAW_LOG_DIR")

    for malformed <- [
          Map.delete(valid, "candidate_id"),
          put_in(valid, ["scenarios", Access.at(0), "status"], "unknown"),
          put_in(valid, ["dispositions", Access.at(0), "evidence"], [%{"path" => "test.exs"}]),
          %{"verdict" => "accept", "findings" => []}
        ] do
      System.put_env("REVIEWER_VERDICT", Jason.encode!(malformed))

      assert {:error, {:malformed_verdict, 0, details}} =
               Kogen.Harness.launch_reviewer("test", "fake", "low", context)

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
    context = %{harness: "codex", executable: executable, args: [], env: []}

    assert {:ok, %{session_id: "developer", message: "current handoff", result: result}} =
             Kogen.Harness.launch_developer("test", "fake", "low", [], context)

    assert result["type"] == "turn.completed"

    File.write!(executable, """
    #!/bin/sh
    cat >/dev/null || true
    printf '%s\\n' '{"type":"thread.started","thread_id":"developer"}' '{"type":"turn.completed","thread_id":"developer"}'
    """)

    File.chmod!(executable, 0o755)

    assert {:ok, %{session_id: "developer", message: ""}} =
             Kogen.Harness.launch_developer("test", "fake", "low", [], context)
  end

  test "a reconnect notification before terminal completion is recoverable" do
    dir = Path.join(System.tmp_dir!(), "kogen-reconnect-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    executable = Path.join(dir, "provider")

    File.write!(executable, """
    #!/bin/sh
    cat >/dev/null
    printf '%s\n' '{"type":"thread.started","thread_id":"developer"}' '{"type":"error","message":"Reconnecting... 1/5"}' '{"type":"item.completed","item":{"type":"agent_message","text":"fresh handoff"}}' '{"type":"turn.completed","thread_id":"developer"}'
    """)

    File.chmod!(executable, 0o755)
    previous = System.get_env("KOGEN_HARNESS")
    System.put_env("KOGEN_HARNESS", executable)

    on_exit(fn ->
      if previous,
        do: System.put_env("KOGEN_HARNESS", previous),
        else: System.delete_env("KOGEN_HARNESS")

      File.rm_rf!(dir)
    end)

    context = %{harness: "codex", executable: executable, args: [], env: []}

    assert {:ok, %{session_id: "developer", message: "fresh handoff"}} =
             Kogen.Harness.launch_developer("test", "fake", "low", [], context)
  end

  test "Build Developer notes are the final agent message, never an owned output file" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "kogen build developer notes #{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    executable = Path.join(dir, "provider")
    argv_log = Path.join(dir, "argv.log")

    original = Map.new(["KOGEN_HARNESS", "OUTPUT_MODE", "ARGV_LOG"], &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(original, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)

      File.rm_rf!(dir)
    end)

    File.write!(executable, """
    #!/bin/sh
    cat >/dev/null || true
    printf '%s\\n' "$*" >> "$ARGV_LOG"
    printf '%s\\n' '{"type":"thread.started","thread_id":"developer"}'
    case "$OUTPUT_MODE" in
      prose) printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"earlier progress"}}' '{"type":"item.completed","item":{"type":"agent_message","text":"All scenarios done; nothing unfinished."}}' ;;
      malformed) printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"{\\"attempt_token\\":"}}' ;;
      empty) : ;;
      provider_failure) exit 19 ;;
    esac
    printf '%s\\n' '{"type":"turn.completed","thread_id":"developer"}'
    """)

    File.chmod!(executable, 0o755)
    System.put_env("KOGEN_HARNESS", executable)
    System.put_env("ARGV_LOG", argv_log)
    context = %{harness: "codex", executable: executable, args: [], env: []}

    for {mode, expected} <- [
          {"prose", "All scenarios done; nothing unfinished."},
          {"malformed", ~s({"attempt_token":)},
          {"empty", ""}
        ] do
      System.put_env("OUTPUT_MODE", mode)

      assert {:ok, %{session_id: "developer", message: ^expected, invocation_evidence: evidence}} =
               Kogen.Harness.launch_build_developer("test", "fake", "low", [], context)

      assert evidence.message == expected

      assert evidence.message_sha256 ==
               Base.encode16(:crypto.hash(:sha256, expected), case: :lower)

      refute Map.has_key?(evidence, :schema)
    end

    System.put_env("OUTPUT_MODE", "provider_failure")

    assert {:error, {:developer_transport_failure, {:provider_exit, 19, _}, evidence}} =
             Kogen.Harness.launch_build_developer("test", "fake", "low", [], context)

    assert evidence.outcome == :provider_failure

    for argv <- String.split(File.read!(argv_log), "\n", trim: true) do
      refute argv =~ "--output-schema"
      refute argv =~ "--output-last-message"
    end
  end

  test "the verdict schema requires a ledger exactly when one is supplied" do
    assert Verdict.schema([]) == Verdict.schema()

    with_ledger = Verdict.schema(["test/a_test.exs", "test/b_test.exs"])
    refute with_ledger == Verdict.schema()
    decoded = Jason.decode!(with_ledger)
    assert "ledger" in decoded["required"]
    assert decoded["additionalProperties"] == false

    ledger_schema = decoded["properties"]["ledger"]
    assert ledger_schema["minItems"] == 2
    assert ledger_schema["maxItems"] == 2

    assert Enum.sort(ledger_schema["items"]["properties"]["path"]["enum"]) ==
             ["test/a_test.exs", "test/b_test.exs"]

    base_message = %{
      "candidate_id" => "c",
      "attempt_token" => "t",
      "verdict" => "accept",
      "scenarios" => [],
      "dispositions" => [],
      "findings" => []
    }

    # `validate/2` accepts `ledger` exactly when the launch requested one.
    assert {:ok, _} = Verdict.validate(base_message, false)
    assert :error = Verdict.validate(base_message, true)

    with_ledger_message =
      Map.put(base_message, "ledger", [
        %{"path" => "test/a_test.exs", "disposition" => "weakening"},
        %{"path" => "test/b_test.exs", "disposition" => "justified: some-scenario"}
      ])

    assert {:ok, _} = Verdict.validate(with_ledger_message, true)
    assert :error = Verdict.validate(with_ledger_message, false)

    # A malformed ledger entry (extra key, blank disposition) is rejected.
    malformed =
      put_in(with_ledger_message, ["ledger", Access.at(0)], %{
        "path" => "test/a_test.exs",
        "disposition" => "weakening",
        "extra" => true
      })

    assert :error = Verdict.validate(malformed, true)
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
