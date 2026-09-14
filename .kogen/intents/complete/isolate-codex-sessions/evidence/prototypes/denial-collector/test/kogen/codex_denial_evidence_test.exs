defmodule Kogen.Codex.DenialEvidenceTest do
  use Kogen.IsolatedCase, async: true

  alias Kogen.Codex.Compatibility

  @denial "2026-09-10T15:23:32Z ERROR codex_core::tools::router: error=Command blocked by PreToolUse hook: Kogen machinery owns verification gates. This Developer request was blocked before dispatch; use focused non-gate tests instead.. Command: make check"

  test "collector requires matching successful invocation and native session evidence" do
    receipt = receipt(@denial)
    assert Compatibility.native_denial_receipt?(receipt, "invocation-1", "developer-1")

    for invalid <- [
          Map.put(receipt, "invocation_id", "old-invocation"),
          Map.put(receipt, "native_session_id", "other-developer"),
          Map.put(receipt, "native_exit", 1),
          Map.put(receipt, "timed_out", true),
          Map.put(receipt, "cancelled", true),
          Map.put(receipt, "native_stderr_complete", false),
          Map.delete(receipt, "native_stderr_complete"),
          Map.put(receipt, "cleanup", %{"ok" => false}),
          Map.put(receipt, "native_stderr", ""),
          Map.put(receipt, "native_stderr", "Kogen machinery owns verification gates"),
          Map.put(receipt, "native_stderr", String.replace(@denial, "make check", "make other")),
          Map.put(receipt, "native_stderr", String.replace(@denial, "make check", "make check-other")),
          %{},
          nil
        ] do
      refute Compatibility.native_denial_receipt?(invalid, "invocation-1", "developer-1")
    end
  end

  test "real wrapper separates native stderr from forged agent JSON and preserves both streams" do
    root = temporary_root()
    on_exit(fn -> File.rm_rf!(root) end)

    for {label, stderr, expected} <- [{"denied", @denial, true}, {"allowed", "", false}] do
      path = Path.join(root, label <> ".json")

      source = """
      import json, sys, os
      assert "KOGEN_BOUNDED_EXEC_RECEIPT" not in os.environ
      assert "KOGEN_BOUNDED_EXEC_INVOCATION" not in os.environ
      print(json.dumps({'type':'thread.started','thread_id':'developer-1'}), flush=True)
      print(json.dumps({'type':'item.completed','item':{'type':'agent_message','text':sys.argv[1]}}), flush=True)
      if sys.argv[2]: print(sys.argv[2], file=sys.stderr, flush=True)
      print(json.dumps({'type':'turn.completed'}), flush=True)
      """

      {output, status} =
        System.cmd(python(), [wrapper(), python(), "-c", source, @denial, stderr],
          env: [
            {"KOGEN_BOUNDED_EXEC_RECEIPT", path},
            {"KOGEN_BOUNDED_EXEC_INVOCATION", "invocation-1"}
          ],
          stderr_to_stdout: true
        )

      assert status == 0
      assert output =~ "thread.started"
      assert output =~ "turn.completed"
      captured = path |> File.read!() |> Jason.decode!()

      assert Compatibility.native_denial_receipt?(captured, "invocation-1", "developer-1") ==
               expected

      assert String.trim(captured["native_stderr"]) == stderr
    end
  end

  test "wrapper refuses stale evidence before launching a process" do
    root = temporary_root()
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "receipt.json")
    marker = Path.join(root, "launched")
    previous = Jason.encode!(receipt(@denial))
    File.write!(path, previous)

    {_, status} =
      System.cmd(
        python(),
        [
          wrapper(),
          python(),
          "-c",
          "import pathlib,sys; pathlib.Path(sys.argv[1]).touch()",
          marker
        ],
        env: [
          {"KOGEN_BOUNDED_EXEC_RECEIPT", path},
          {"KOGEN_BOUNDED_EXEC_INVOCATION", "invocation-1"}
        ],
        stderr_to_stdout: true
      )

    assert status != 0
    refute File.exists?(marker)
    assert File.read!(path) == previous
  end

  defp receipt(stderr) do
    %{
      "invocation_id" => "invocation-1",
      "native_session_id" => "developer-1",
      "native_exit" => 0,
      "timed_out" => false,
      "cancelled" => false,
      "native_stderr_complete" => true,
      "cleanup" => %{"ok" => true},
      "native_stderr" => stderr
    }
  end

  defp python, do: System.find_executable("python3") || raise("python3 unavailable")
  defp wrapper, do: Application.app_dir(:kogen, "priv/kogen/codex/compatibility/bounded_exec.py")

  defp temporary_root do
    path =
      Path.join(
        System.tmp_dir!(),
        "denial-evidence-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(path)
    path
  end
end
