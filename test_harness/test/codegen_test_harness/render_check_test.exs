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
end
