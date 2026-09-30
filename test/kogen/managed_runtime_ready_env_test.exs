defmodule Kogen.ManagedRuntimeReadyEnvTest do
  # These tests set KOGEN_PROVIDERS_DENIED, a process-global that every other
  # async module shares; each runs in its own VM so the mutation and its
  # restore can never race another test.
  use Kogen.IsolatedCase, async: true

  alias Kogen.ManagedRuntimeReady

  test "provider-denied preparation installs and returns both exact managed pins" do
    System.put_env("KOGEN_PROVIDERS_DENIED", "1")

    codex = ManagedRuntimeReady.codex_version()
    claude = ManagedRuntimeReady.claude_code_version()

    assert %{codex: %{"version" => ^codex}, claude_code: %{"version" => ^claude}} =
             ManagedRuntimeReady.prepare!(%{
               codex: fn ->
                 {:ok,
                  %{
                    "version" => Kogen.ManagedRuntimeReady.codex_version(),
                    "executable" => "/managed/codex"
                  }}
               end,
               claude_code: fn ->
                 {:ok,
                  %{
                    "version" => Kogen.ManagedRuntimeReady.claude_code_version(),
                    "executable" => "/managed/claude"
                  }}
               end
             })
  end

  test "read-only verification returns both installed pins without invoking installers" do
    System.put_env("KOGEN_PROVIDERS_DENIED", "1")
    Process.put(:runtime_inspections, [])

    verified =
      ManagedRuntimeReady.verify!(%{
        codex: fn ->
          Process.put(:runtime_inspections, [:codex | Process.get(:runtime_inspections)])

          {:ok,
           %{
             "version" => Kogen.ManagedRuntimeReady.codex_version(),
             "executable" => "/managed/codex"
           }}
        end,
        claude_code: fn ->
          Process.put(:runtime_inspections, [:claude_code | Process.get(:runtime_inspections)])

          {:ok,
           %{
             "version" => Kogen.ManagedRuntimeReady.claude_code_version(),
             "executable" => "/managed/claude"
           }}
        end
      })

    assert verified == %{
             codex: %{
               "version" => Kogen.ManagedRuntimeReady.codex_version(),
               "executable" => "/managed/codex"
             },
             claude_code: %{
               "version" => Kogen.ManagedRuntimeReady.claude_code_version(),
               "executable" => "/managed/claude"
             }
           }

    assert Enum.sort(Process.get(:runtime_inspections)) == [:claude_code, :codex]
  end
end
