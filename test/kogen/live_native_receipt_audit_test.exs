Code.require_file("../support/live_native_receipt_audit.ex", __DIR__)

defmodule Kogen.LiveNativeReceiptAuditTest do
  use ExUnit.Case, async: true

  test "accepts exact current-session captures with completion and usage" do
    dir = fixture!()
    on_exit(fn -> File.rm_rf!(dir) end)
    write_stream!(dir, 1, "developer", completed())
    write_stream!(dir, 2, "developer", completed())
    write_stream!(dir, 3, "reviewer", completed())

    assert %{provider_invocations: 3, required_invocations: 3, usage_by_capture: usage} =
             Kogen.LiveNativeReceiptAudit.audit!(dir, %{"developer" => 2, "reviewer" => 1})

    assert length(usage) == 3
  end

  test "owner audit rejects missing, wrong-session, incomplete, usage-less, and failed captures" do
    corruptions = [
      {:missing, fn _dir -> :ok end, ~r/expected 1 completed native capture/},
      {:wrong_session, fn dir -> write_stream!(dir, 1, "other", completed()) end,
       ~r/expected 1 completed native capture/},
      {:incomplete, fn dir -> write_stream!(dir, 1, "required", []) end,
       ~r/one turn.completed event/},
      {:usage, fn dir -> write_stream!(dir, 1, "required", [%{"type" => "turn.completed"}]) end,
       ~r/needs a usage map/},
      {:failed,
       fn dir ->
         write_stream!(dir, 1, "required", [
           %{"type" => "turn.failed"},
           completed()
         ])
       end, ~r/failed provider event/}
    ]

    Enum.each(corruptions, fn {_name, corrupt, message} ->
      dir = fixture!()
      corrupt.(dir)

      assert_raise ArgumentError, message, fn ->
        Kogen.LiveNativeReceiptAudit.audit!(dir, %{"required" => 1})
      end

      File.rm_rf!(dir)
    end)
  end

  test "malformed structured lines cannot replace a required completion" do
    dir = fixture!()
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "raw-stream-100-1.jsonl")

    File.write!(
      path,
      Jason.encode!(%{"type" => "thread.started", "thread_id" => "required"}) <> "\nnot-json\n"
    )

    assert_raise ArgumentError, ~r/one turn.completed event/, fn ->
      Kogen.LiveNativeReceiptAudit.audit!(dir, %{"required" => 1})
    end
  end

  test "Claude Code stream-json captures bind one init session and one successful result" do
    dir = fixture!()
    on_exit(fn -> File.rm_rf!(dir) end)
    write_claude!(dir, 1, "developer", [claude_result()])
    write_claude!(dir, 2, "developer", [claude_result()])
    write_claude!(dir, 3, "reviewer", [claude_result()])

    assert %{provider_invocations: 3, required_invocations: 3} =
             Kogen.LiveNativeReceiptAudit.audit!(dir, %{"developer" => 2, "reviewer" => 1})

    for {tail, message} <- [
          {[], ~r/one result event/},
          {[Map.delete(claude_result(), "usage")], ~r/needs a usage map/},
          {[
             Map.merge(claude_result(), %{
               "subtype" => "error_during_execution",
               "is_error" => true
             })
           ], ~r/failed provider event/},
          {[Map.put(claude_result(), "session_id", "other")], ~r/exactly one native session/}
        ] do
      bad = fixture!()
      write_claude!(bad, 1, "required", tail)

      assert_raise ArgumentError, message, fn ->
        Kogen.LiveNativeReceiptAudit.audit!(bad, %{"required" => 1})
      end

      File.rm_rf!(bad)
    end
  end

  test "Claude Code captures may re-emit init and result within one session" do
    dir = fixture!()
    on_exit(fn -> File.rm_rf!(dir) end)
    init = %{"type" => "system", "subtype" => "init", "session_id" => "s"}

    result = fn n ->
      Map.put(claude_result(), "session_id", "s") |> Map.put("usage", %{"input_tokens" => n})
    end

    write_events!(dir, 1, [init, init, result.(1), init, result.(2)])

    assert %{usage_by_capture: [%{session_id: "s", usage: %{"input_tokens" => 3}}]} =
             Kogen.LiveNativeReceiptAudit.audit!(dir, %{"s" => 1})

    for {events, message} <- [
          {[init, %{init | "session_id" => "t"}, result.(1)], ~r/exactly one native session/},
          {[
             init,
             result.(1),
             Map.put(init, "session_id", "s"),
             Map.put(result.(1), "session_id", "t")
           ], ~r/exactly one native session/},
          {[init, result.(1), init, Map.put(result.(1), "is_error", true)],
           ~r/failed provider event/},
          {[init, Map.put(result.(1), "subtype", "error_max_turns"), init, result.(1)],
           ~r/failed provider event/},
          {[init, result.(1), init], ~r/end with a result/}
        ] do
      bad = fixture!()
      write_events!(bad, 1, events)

      assert_raise ArgumentError, message, fn ->
        Kogen.LiveNativeReceiptAudit.audit!(bad, %{"s" => 1})
      end

      File.rm_rf!(bad)
    end
  end

  test "a Reviewer session has one receipt, or two only with a matching evidence addendum" do
    accept = fn overrides ->
      Map.merge(
        %{
          "session_id" => "rev",
          "attempt_token" => "tok",
          "candidate_id" => "cand",
          "verdict" => "accept",
          "scenarios" => [],
          "dispositions" => [],
          "findings" => []
        },
        overrides
      )
    end

    addendum = [%{"evidence_addendum" => %{"reviewer_session_id" => "rev"}}]
    other = [%{"evidence_addendum" => %{"reviewer_session_id" => "someone-else"}}]

    cases = [
      {[accept.(%{})], [], :ok},
      {[accept.(%{}), accept.(%{})], addendum, :ok},
      {[accept.(%{}), accept.(%{})], [], ~r/expected one Reviewer receipt/},
      {[accept.(%{}), accept.(%{})], other, ~r/expected one Reviewer receipt/},
      {[accept.(%{}), accept.(%{}), accept.(%{})], addendum, ~r/expected one Reviewer receipt/},
      {[accept.(%{}), accept.(%{"verdict" => "rework"})], addendum, ~r/must be accept/},
      {[accept.(%{}), accept.(%{"attempt_token" => "x"})], addendum, ~r/same attempt/},
      {[accept.(%{}), accept.(%{"candidate_id" => "x"})], addendum, ~r/same attempt/},
      {[accept.(%{}), Map.delete(accept.(%{}), "findings")], addendum, ~r/needs findings/}
    ]

    for {receipts, attempts, expected} <- cases do
      dir = fixture!()
      write_stream!(dir, 1, "rev", completed())
      write_stream!(dir, 2, "rev", completed())

      File.write!(
        Path.join(dir, "reviewer-verdicts.jsonl"),
        Enum.map_join(receipts, "\n", &Jason.encode!/1) <> "\n"
      )

      run = fn -> Kogen.LiveNativeReceiptAudit.audit!(dir, %{"rev" => 2}, ["rev"], attempts) end

      if expected == :ok,
        do: assert(%{provider_invocations: 2} = run.()),
        else: assert_raise(ArgumentError, expected, run)

      File.rm_rf!(dir)
    end
  end

  defp write_events!(dir, sequence, events) do
    body = Enum.map_join(events, "\n", &Jason.encode!/1) <> "\n"
    File.write!(Path.join(dir, "raw-stream-100-#{sequence}.jsonl"), body)
  end

  defp claude_result,
    do: %{
      "type" => "result",
      "subtype" => "success",
      "is_error" => false,
      "usage" => %{"input_tokens" => 1}
    }

  defp write_claude!(dir, sequence, session, tail) do
    events = [
      %{"type" => "system", "subtype" => "init", "session_id" => session}
      | Enum.map(tail, &Map.put_new(&1, "session_id", session))
    ]

    body = Enum.map_join(events, "\n", &Jason.encode!/1) <> "\n"
    File.write!(Path.join(dir, "raw-stream-100-#{sequence}.jsonl"), body)
  end

  defp completed, do: %{"type" => "turn.completed", "usage" => %{"input_tokens" => 1}}

  defp write_stream!(dir, sequence, session, tail) do
    events = [%{"type" => "thread.started", "thread_id" => session} | List.wrap(tail)]
    body = Enum.map_join(events, "\n", &Jason.encode!/1) <> "\n"
    File.write!(Path.join(dir, "raw-stream-100-#{sequence}.jsonl"), body)
  end

  defp fixture! do
    dir =
      Path.join(
        System.tmp_dir!(),
        "kogen-native-receipt-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    dir
  end
end
