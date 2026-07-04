defmodule CodegenTestHarness.RenderCheckTest do
  @moduledoc """
  Hermetic tests for render-check.js and phoenix-server.js.

  Does NOT invoke a real browser or Phoenix server. Verifies:
  1. Both scripts pass `node --check` (syntax valid).
  2. Invoking render-check.js with a missing output dir emits
     `RENDER_VERDICT=INCONCLUSIVE:...` to stdout (not a crash).

  These tests are fast and deterministic — no LLM, no Playwright, no server.
  """

  use ExUnit.Case, async: true

  @codegen_dir Path.expand("../../../", __DIR__)
  @render_check Path.join([
                  @codegen_dir,
                  "harnesses",
                  "claude",
                  "hooks",
                  "lib",
                  "render-check.js"
                ])
  @phoenix_server Path.join([
                    @codegen_dir,
                    "harnesses",
                    "claude",
                    "hooks",
                    "lib",
                    "phoenix-server.js"
                  ])
  @screenshot_js Path.join([
                   @codegen_dir,
                   "test_harness",
                   "bench",
                   "screenshot.js"
                 ])

  describe "node --check" do
    test "render-check.js has valid syntax" do
      assert File.exists?(@render_check), "render-check.js not found at #{@render_check}"

      {output, exit_code} =
        System.cmd("node", ["--check", @render_check], stderr_to_stdout: true)

      assert exit_code == 0, "render-check.js failed node --check:\n#{output}"
    end

    test "phoenix-server.js has valid syntax" do
      assert File.exists?(@phoenix_server), "phoenix-server.js not found at #{@phoenix_server}"

      {output, exit_code} =
        System.cmd("node", ["--check", @phoenix_server], stderr_to_stdout: true)

      assert exit_code == 0, "phoenix-server.js failed node --check:\n#{output}"
    end
  end

  describe "render-check.js smoke invocation" do
    test "emits RENDER_VERDICT= line for missing output dir" do
      {output, exit_code} =
        System.cmd(
          "node",
          [@render_check, "--mode", "static", "/nonexistent/path/that/does/not/exist"],
          stderr_to_stdout: true,
          env: [{"CODEGEN_DIR", @codegen_dir}]
        )

      assert exit_code == 0, "render-check.js must always exit 0, got #{exit_code}:\n#{output}"

      assert output =~ "RENDER_VERDICT=",
             "expected RENDER_VERDICT= line in output, got:\n#{output}"
    end
  end

  describe "screenshot.js Phoenix pre-warm ordering" do
    test "mix deps.get + mix compile precede the readiness wait and server spawn" do
      assert File.exists?(@screenshot_js), "screenshot.js not found at #{@screenshot_js}"
      source = File.read!(@screenshot_js)

      deps_idx = find_index!(source, "mix deps.get")
      compile_idx = find_index!(source, "mix compile")
      spawn_idx = find_index!(source, "startPhoenixServer(cwd")
      wait_idx = find_index!(source, "waitForHttp200(port")

      assert deps_idx < wait_idx,
             "invariant violated: deps.get+compile must precede the readiness wait " <>
               "so the 30s window covers only server boot, not cold dep install " <>
               "(deps_idx=#{deps_idx}, wait_idx=#{wait_idx})"

      assert compile_idx < wait_idx,
             "invariant violated: deps.get+compile must precede the readiness wait " <>
               "so the 30s window covers only server boot, not cold dep install " <>
               "(compile_idx=#{compile_idx}, wait_idx=#{wait_idx})"

      assert deps_idx < spawn_idx,
             "invariant violated: deps.get+compile must precede the readiness wait " <>
               "so the 30s window covers only server boot, not cold dep install " <>
               "(deps_idx=#{deps_idx}, spawn_idx=#{spawn_idx})"

      assert compile_idx < spawn_idx,
             "invariant violated: deps.get+compile must precede the readiness wait " <>
               "so the 30s window covers only server boot, not cold dep install " <>
               "(compile_idx=#{compile_idx}, spawn_idx=#{spawn_idx})"
    end

    test "cold-boot failures in deps.get/compile are surfaced, not swallowed" do
      source = File.read!(@screenshot_js)

      start_idx = find_index!(source, "running mix deps.get")
      end_idx = find_index!(source, "startPhoenixServer(cwd")
      phoenix_prewarm_region = binary_part(source, start_idx, end_idx - start_idx)

      exit_count =
        phoenix_prewarm_region
        |> String.split("process.exit(1)")
        |> length()
        |> Kernel.-(1)

      assert exit_count == 2,
             "expected exactly two process.exit(1) calls in the deps.get/compile " <>
               "pre-warm region (one per catch block) so cold-boot failures fail loud " <>
               "instead of being silently swallowed, got #{exit_count}"
    end
  end

  defp find_index!(source, substring) do
    case :binary.match(source, substring) do
      {idx, _len} -> idx
      :nomatch -> flunk("expected to find #{inspect(substring)} in screenshot.js source")
    end
  end
end
