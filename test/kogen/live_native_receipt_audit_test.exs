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
