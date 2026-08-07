defmodule CodegenTestHarness.CallContractTest do
  @moduledoc """
  Hermetic tests for `run_codegen_call/3` harness-name mapping.

  `codegen-call` requires `--harness=claude_code`.
  `Fixtures.harness/0` returns `"claude"` (short form used by `codegen-build`).
  `Fixtures.codegen_call_harness/0` MUST map `"claude"` → `"claude_code"`.

  These tests are fast and deterministic — no LLM, no external process.
  """

  use ExUnit.Case, async: false

  alias CodegenTestHarness.Fixtures

  @codegen_call Path.expand("../../../codegen-call", __DIR__)
  @orchestration_loop Path.expand(
                        "../../lib/codegen_test_harness/orchestration_loop.ex",
                        __DIR__
                      )

  test "run_call_split binds dispatch lifetime to the BEAM OS pid" do
    source = File.read!(@orchestration_loop)
    assert source =~ "{\"CODEGEN_CALL_OWNER_OS_PID\", System.pid()}"
  end

  describe "codegen-call --role removed contract" do
    test "usage text does not mention --role" do
      codegen_call = @codegen_call

      {output, exit_code} = System.cmd(codegen_call, [], stderr_to_stdout: true, env: [])

      assert exit_code == 2, "expected exit 2 on missing args, got #{exit_code}"

      refute output =~ ~r/--role/,
             "expected usage to NOT mention --role (it is dead code), got:\n#{output}"
    end

    test "--role=x exits 2 as unknown flag" do
      codegen_call = @codegen_call

      {_output, exit_code} =
        System.cmd(
          codegen_call,
          [
            "--harness=claude_code",
            "--role=x",
            "--model=haiku",
            "--effort=low",
            "--system-prompt",
            "@/nonexistent",
            "prompt"
          ],
          stderr_to_stdout: true,
          env: []
        )

      assert exit_code == 2, "expected exit 2 for unknown flag --role, got #{exit_code}"
    end

    test "fixture argv flags are all accepted by codegen-call parser" do
      # Sentinel harness fails at validation (not parse) only if every
      # preceding --* flag was recognized by the parser.
      {output, exit_code} =
        System.cmd(
          @codegen_call,
          [
            "--harness=__bogus__",
            "--model=x",
            "--effort=low",
            "--system-prompt=@/nonexistent",
            "--json-schema=@/nonexistent",
            "prompt"
          ],
          stderr_to_stdout: true,
          env: []
        )

      assert exit_code == 2, "expected exit 2, got #{exit_code}:\n#{output}"

      assert output =~ ~r/must be "claude_code"/,
             "expected parser to reach harness validation (all fixture flags known), got:\n#{output}"

      refute output =~ ~r/unknown flag/,
             "an unknown flag means a fixture argv flag is NOT accepted by codegen-call:\n#{output}"
    end
  end

  describe "no caller in the tree passes a flag codegen-call rejects" do
    @codegen_root Path.expand("../../..", __DIR__)

    test "codegen-document's real codegen-call invocation does not pass --role" do
      # codegen-document previously passed --role usage-rules; codegen-call
      # rejects any --role flag outright (removed 2026-06-25). Scope the
      # check to codegen-document's actual invocation line(s), not a
      # repo-wide text grep — that would false-positive on doc mentions
      # (context/*.md), this test's own name, and
      # codegen-call_test.sh's INTENTIONAL --role=x rejection fixture.
      codegen_document_path = Path.join(@codegen_root, "codegen-document")
      source = File.read!(codegen_document_path)

      invocation_lines =
        source
        |> String.split("\n")
        |> Enum.filter(&(&1 =~ ~r/codegen-call\b/))

      assert invocation_lines != [], "expected to find a codegen-call invocation line"

      refute Enum.any?(invocation_lines, &(&1 =~ ~r/--role/)),
             "codegen-document still passes --role to codegen-call (rejected, removed 2026-06-25):\n#{Enum.join(invocation_lines, "\n")}"
    end

    test "every literal --system-prompt @<path> target in codegen-document exists" do
      # codegen-document's SYSTEM_PROMPT_FILE must resolve to a real,
      # trackable (.md, not .gitignore'd *-system-prompt.txt) file.
      codegen_document_path = Path.join(@codegen_root, "codegen-document")
      source = File.read!(codegen_document_path)

      assert source =~ ~r/SYSTEM_PROMPT_FILE="\$CODEGEN_DIR\/harnesses\/claude\/([^"]+)"/,
             "expected codegen-document to declare SYSTEM_PROMPT_FILE"

      [_, rel_path] =
        Regex.run(~r/SYSTEM_PROMPT_FILE="\$CODEGEN_DIR\/harnesses\/claude\/([^"]+)"/, source)

      assert String.ends_with?(rel_path, ".md"),
             "SYSTEM_PROMPT_FILE must be .md — a .txt would be silently untracked by .gitignore's *-system-prompt.txt pattern, got: #{rel_path}"

      full_path = Path.join([@codegen_root, "harnesses", "claude", rel_path])

      assert File.exists?(full_path),
             "codegen-document's SYSTEM_PROMPT_FILE does not exist on disk: #{full_path}"
    end

    test "codegen-document's whole-lock main() returns non-zero when failed_rules > 0" do
      codegen_document_path = Path.join(@codegen_root, "codegen-document")
      source = File.read!(codegen_document_path)

      assert source =~ ~r/if \[ "\$failed_rules" -gt 0 \]/,
             "expected main() to branch on failed_rules > 0"

      # The branch must actually return/exit non-zero, not just print a warning —
      # otherwise scaffold.sh's FATAL guard downstream is dead code.
      [_, branch_body] =
        Regex.run(
          ~r/if \[ "\$failed_rules" -gt 0 \]; then(.*?)fi/s,
          String.replace(source, "\n", "")
        )

      assert branch_body =~ "return 1",
             "expected the failed_rules>0 branch to `return 1` so a non-zero exit propagates, got branch body: #{branch_body}"
    end
  end

  describe "envelope decode survives stderr noise ahead of stdout" do
    # These tests exercise the SAME `sh -c 'exec "$@" 2>"$CG_ERR"'` stream-split
    # mechanism used by both `OrchestrationLoop.run_call_split/4` (defp) and
    # `Fixtures.run_codegen_call/3` — the fixture under test is a stand-in
    # child process that writes a diagnostic line to stderr THEN a JSON
    # envelope to stdout, exactly like `call-dispatch.sh`'s watchdog
    # grace-kill path. Testing via a temp fixture script (rather than the
    # real `codegen-call` binary, which requires a live LLM call) keeps this
    # hermetic while proving the exact contract: a merged stream corrupts
    # the parse, a split stream does not.
    setup do
      fixture_path =
        Path.join(
          System.tmp_dir!(),
          "noisy_envelope_#{:erlang.unique_integer([:positive])}.sh"
        )

      File.write!(fixture_path, """
      #!/bin/sh
      echo "codegen-call: watchdog killing claude ... result already emitted" >&2
      echo '{"result":{"status":"success"}}'
      exit 0
      """)

      File.chmod!(fixture_path, 0o755)

      on_exit(fn -> File.rm(fixture_path) end)

      {:ok, fixture_path: fixture_path}
    end

    test "RED-first: a merged stdout+stderr stream corrupts the JSON parse", %{
      fixture_path: fixture_path
    } do
      {merged, 0} = System.cmd(fixture_path, [], stderr_to_stdout: true)

      assert {:error, %Jason.DecodeError{}} = Jason.decode(merged),
             "expected the merged stream to fail JSON decode (this is the bug being fixed), got: #{inspect(Jason.decode(merged))}"
    end

    test "stream-split wrapper: stdout decodes cleanly, stderr captured separately", %{
      fixture_path: fixture_path
    } do
      err_path =
        Path.join(System.tmp_dir!(), "envelope_stderr_#{:erlang.unique_integer([:positive])}.log")

      try do
        {stdout, exit_code} =
          System.cmd(
            "sh",
            ["-c", ~s(exec "$@" 2>"$CG_ERR"), "sh", fixture_path],
            env: [{"CG_ERR", err_path}],
            stderr_to_stdout: false
          )

        stderr = File.read!(err_path)

        assert exit_code == 0
        assert {:ok, %{"result" => %{"status" => "success"}}} = Jason.decode(stdout)
        assert stderr =~ "watchdog killing claude"
      after
        File.rm(err_path)
      end
    end

    test "hostile argv (embedded shell metacharacters) is passed as data, not executed", %{
      fixture_path: _fixture_path
    } do
      # A prompt/arg containing shell metacharacters must never be
      # interpreted by the `sh -c` wrapper — `exec "$@"` passes argv
      # positionally, never through a second shell-eval.
      canary_path =
        Path.join(System.tmp_dir!(), "canary_#{:erlang.unique_integer([:positive])}.txt")

      on_exit(fn -> File.rm(canary_path) end)

      hostile_arg = "arg with spaces; touch #{canary_path}; echo pwned"

      echo_fixture =
        Path.join(System.tmp_dir!(), "echo_argv_#{:erlang.unique_integer([:positive])}.sh")

      File.write!(echo_fixture, """
      #!/bin/sh
      echo "{\\"result\\":{\\"status\\":\\"success\\",\\"argv\\":\\"$1\\"}}"
      """)

      File.chmod!(echo_fixture, 0o755)
      on_exit(fn -> File.rm(echo_fixture) end)

      err_path =
        Path.join(System.tmp_dir!(), "canary_stderr_#{:erlang.unique_integer([:positive])}.log")

      try do
        {stdout, 0} =
          System.cmd(
            "sh",
            ["-c", ~s(exec "$@" 2>"$CG_ERR"), "sh", echo_fixture, hostile_arg],
            env: [{"CG_ERR", err_path}],
            stderr_to_stdout: false
          )

        {:ok, decoded} = Jason.decode(stdout)

        assert decoded["result"]["argv"] == hostile_arg
        refute File.exists?(canary_path), "hostile arg must not be shell-evaluated"
      after
        File.rm(err_path)
      end
    end
  end

  describe "codegen_call_harness/0" do
    test "maps \"claude\" to \"claude_code\" when HARNESS env is unset" do
      # Ensure HARNESS env is unset (default path)
      original = System.get_env("HARNESS")

      try do
        System.delete_env("HARNESS")
        assert Fixtures.codegen_call_harness() == "claude_code"
      after
        if original, do: System.put_env("HARNESS", original)
      end
    end

    test "maps \"claude\" to \"claude_code\" when HARNESS=claude" do
      original = System.get_env("HARNESS")

      try do
        System.put_env("HARNESS", "claude")
        assert Fixtures.codegen_call_harness() == "claude_code"
      after
        case original do
          nil -> System.delete_env("HARNESS")
          v -> System.put_env("HARNESS", v)
        end
      end
    end
  end
end
