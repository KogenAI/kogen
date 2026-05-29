defmodule CodegenTestHarness.BenchArtifacts do
  @moduledoc """
  Captures PNG screenshots of built static-stack sites as benchmark artifacts.

  `capture_screenshot/4` invokes `test_harness/bench/screenshot.js` via Node
  with a deterministic 1280×720 viewport. Screenshots are written to
  `<run_dir>/runs/<harness>/<stack>/<test_name>.png` alongside JSONL records.

  **Scope**: static stacks (`:static`, `:hugo`, `:vite_react`, `:vite_vue`,
  `:multilingual`) and the `:phoenix` stack. Modes stacks are no-ops — no
  website to render. Phoenix stacks spawn `mix phx.server` on a dynamic port,
  poll for HTTP 200, capture the screenshot, then SIGTERM/SIGKILL the process
  group.

  **Non-fatal**: screenshot failures (missing Playwright, build errors, timeouts)
  are logged to stderr and return `{:error, reason}` rather than raising.
  Missing Playwright returns `:ok` (treated as "skip", not "failure").
  """

  alias CodegenTestHarness.BenchCommon

  require Logger

  @script_path Path.expand("../../bench/screenshot.js", __DIR__)
  @timeout_ms 210_000

  @skipped_stacks ["modes", :modes]

  @type capture_result :: :ok | {:error, String.t()}

  @doc """
  Captures a screenshot of the built site in `cwd` for the given `stack`.

  `run_dir` is the `BENCH_RUN_DIR` value. `harness` is a string (`"claude"` or
  `"pi"`). `test_name` is used as the PNG filename.

  Returns `:ok` on success (PNG written) or when the stack is skipped.
  Returns `{:error, reason}` when the Node script fails or the tool is missing.
  Never raises.
  """
  @spec capture_screenshot(String.t(), String.t() | atom(), String.t(), String.t()) ::
          capture_result()
  def capture_screenshot(cwd, stack, run_dir, test_name) do
    if stack in @skipped_stacks do
      :ok
    else
      do_capture(cwd, stack, run_dir, test_name)
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp do_capture(cwd, stack, run_dir, test_name) do
    stack_str = to_string(stack)
    harness = detect_harness()
    out_dir = Path.join([run_dir, "runs", harness, stack_str])
    out_path = Path.join(out_dir, "#{test_name}.png")
    File.mkdir_p!(out_dir)

    node_path = System.find_executable("node")

    if is_nil(node_path) do
      Logger.warning("node not found — skipping screenshot capture for #{test_name}")
      :ok
    else
      invoke_node(node_path, cwd, stack_str, out_path, test_name)
    end
  end

  defp invoke_node(node_path, cwd, stack_str, out_path, test_name) do
    args = ["--cwd", cwd, "--stack", stack_str, "--out", out_path]

    {output, exit_code} =
      run_with_timeout(node_path, [@script_path | args], @timeout_ms)

    cond do
      playwright_missing?(output) ->
        Logger.warning("playwright not installed — skipping screenshot capture for #{test_name}")
        :ok

      exit_code == 0 ->
        :ok

      true ->
        msg = "screenshot.js failed (exit #{exit_code}): #{String.trim(output)}"
        Logger.warning(msg)
        {:error, msg}
    end
  end

  defp playwright_missing?(msg) do
    String.contains?(msg, ["Cannot find module 'playwright'", "Cannot find package 'playwright'"])
  end

  defp detect_harness do
    BenchCommon.detect_harness()
  end

  defp run_with_timeout(cmd, args, timeout_ms) do
    shell_args = Enum.map_join([cmd | args], " ", &shell_quote/1)

    deadline = System.monotonic_time(:millisecond) + timeout_ms

    port =
      Port.open(
        {:spawn, shell_args <> " </dev/null"},
        [:binary, :exit_status, :stderr_to_stdout]
      )

    collect_port(port, [], deadline)
  end

  defp collect_port(port, acc, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      kill_port(port)
      output = IO.iodata_to_binary(Enum.reverse(acc))
      msg = "screenshot capture timed out after #{div(@timeout_ms, 1000)}s"
      {output <> "\n" <> msg, 1}
    else
      receive do
        {^port, {:data, chunk}} ->
          collect_port(port, [chunk | acc], deadline)

        {^port, {:exit_status, code}} ->
          {IO.iodata_to_binary(Enum.reverse(acc)), code}

        {^port, :closed} ->
          collect_port(port, acc, deadline)
      after
        remaining ->
          kill_port(port)
          output = IO.iodata_to_binary(Enum.reverse(acc))
          msg = "screenshot capture timed out after #{div(@timeout_ms, 1000)}s"
          {output <> "\n" <> msg, 1}
      end
    end
  end

  defp kill_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        System.cmd("kill", ["-9", "#{os_pid}"], stderr_to_stdout: true)
        System.cmd("pkill", ["-9", "-P", "#{os_pid}"], stderr_to_stdout: true)

      _ ->
        :ok
    end

    try do
      Port.close(port)
    rescue
      ArgumentError -> :already_closed
    end
  end

  defp shell_quote(arg) do
    "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end
end
