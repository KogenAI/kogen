defmodule Kogen.ManagedRuntimeReadyTest do
  use ExUnit.Case, async: true

  alias Kogen.ManagedRuntimeReady

  test "preparation fails closed on a wrong installed pin" do
    assert_raise RuntimeError,
                 ~r/Codex pin mismatch: expected #{Regex.escape(ManagedRuntimeReady.codex_version())}, got "0\.156\.1"/,
                 fn ->
                   ManagedRuntimeReady.prepare!(%{
                     codex: fn -> {:ok, %{"version" => "0.156.1"}} end,
                     claude_code: fn ->
                       flunk("Claude should not install after Codex pin failure")
                     end
                   })
                 end

    assert_raise RuntimeError,
                 ~r/Claude Code pin mismatch: expected #{Regex.escape(ManagedRuntimeReady.claude_code_version())}, got "2\.1\.281"/,
                 fn ->
                   ManagedRuntimeReady.prepare!(%{
                     codex: fn ->
                       {:ok, %{"version" => Kogen.ManagedRuntimeReady.codex_version()}}
                     end,
                     claude_code: fn -> {:ok, %{"version" => "2.1.281"}} end
                   })
                 end
  end

  test "the pins are read from the installers' single source" do
    root = Path.expand("../..", __DIR__)

    for {file, expected} <- [
          {"priv/kogen/codex/install.py", ManagedRuntimeReady.codex_version()},
          {"priv/kogen/claude_code/install.py", ManagedRuntimeReady.claude_code_version()}
        ] do
      [_, pinned] =
        Regex.run(~r/^INITIAL_VERSION = "([^"]+)"/m, File.read!(Path.join(root, file)))

      assert pinned == expected, file
    end

    assert ManagedRuntimeReady.claude_code_version() == Kogen.ClaudeCode.pinned_version()
  end

  test "preparation surfaces an installer failure without trying providers" do
    assert_raise RuntimeError, "managed Codex preparation failed: unavailable", fn ->
      ManagedRuntimeReady.prepare!(%{
        codex: fn -> {:error, "unavailable"} end,
        claude_code: fn -> flunk("Claude should not install after Codex fails") end
      })
    end
  end

  test "catalog prepare missing-pin control fails before a provider call" do
    {output, status} =
      System.cmd("mix", ["run", "-e", "Kogen.ManagedRuntimeReady.prepare_for_target!()"],
        cd: System.fetch_env!("KOGEN_TEST_ROOT"),
        stderr_to_stdout: true,
        env: [
          {"KOGEN_PREPARE_FORCE_SCOPE", "fail"},
          {"KOGEN_PROVIDERS_DENIED", "1"},
          {"KOGEN_ROLE", nil}
        ]
      )

    refute status == 0

    frames =
      output
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "KOGEN_PREPARE_RESULT\t"))

    assert length(frames) == 1
    frame = hd(frames) |> String.replace_prefix("KOGEN_PREPARE_RESULT\t", "") |> Jason.decode!()
    assert frame["class"] == "environment"
    assert frame["reason"] =~ "Codex"
  end

  test "read-only verification fails closed for missing, wrong or invalid inspected runtimes" do
    assert_raise RuntimeError, ~r/managed Codex verification failed: not installed/, fn ->
      ManagedRuntimeReady.verify!(%{
        codex: fn -> {:error, "not installed"} end,
        claude_code: fn -> flunk("Claude inspection should not run after Codex fails") end
      })
    end

    assert_raise RuntimeError,
                 ~r/Claude Code pin mismatch: expected #{Regex.escape(ManagedRuntimeReady.claude_code_version())}, got "2\.1\.281"/,
                 fn ->
                   ManagedRuntimeReady.verify!(%{
                     codex: fn ->
                       {:ok, %{"version" => Kogen.ManagedRuntimeReady.codex_version()}}
                     end,
                     claude_code: fn -> {:ok, %{"version" => "2.1.281"}} end
                   })
                 end

    assert_raise RuntimeError, ~r/managed Codex verification returned an invalid result/, fn ->
      ManagedRuntimeReady.verify!(%{
        codex: fn -> {:ok, nil} end,
        claude_code: fn ->
          flunk("Claude inspection should not run after invalid Codex result")
        end
      })
    end
  end
end
