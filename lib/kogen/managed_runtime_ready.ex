defmodule Kogen.ManagedRuntimeReady do
  @moduledoc """
  Installs and checks the exact managed runtimes selected by this checkout.

  This is a provider-free preparation step for future Build targets. The
  installers stage native artifacts only; authentication and model access stay
  with the Build's normal readiness and launch paths.
  """
  use Boundary, deps: [Kogen.Codex, Kogen.ClaudeCode], exports: []

  @codex_version "0.159.2"
  @claude_code_version Kogen.ClaudeCode.pinned_version()

  @doc "The exact managed Codex version this checkout pins; tests read it from here."
  def codex_version, do: @codex_version

  @doc "The exact managed Claude Code version this checkout pins."
  def claude_code_version, do: @claude_code_version

  @doc "Install and verify both managed runtime pins without contacting a model provider."
  def prepare! do
    result =
      prepare!(%{
        codex: &Kogen.Codex.install/0,
        claude_code: &Kogen.ClaudeCode.install/0
      })

    trace_prepare()
    result
  end

  @doc "Catalog prepare entry with a provider-denied missing-pin rehearsal control."
  def prepare_for_target! do
    if System.get_env("KOGEN_PREPARE_FORCE_SCOPE") == "fail" do
      missing =
        Path.join(System.tmp_dir!(), "kogen-missing-codex-#{System.unique_integer([:positive])}")

      # The rehearsal hands verification an explicit inspector for an empty
      # managed root; no process-global environment is touched.
      inspectors = %{
        codex: fn -> {:error, "no managed Codex runtime under #{missing}"} end,
        claude_code: fn -> {:error, "no managed Claude Code runtime under #{missing}"} end
      }

      try do
        verify!(inspectors)
        raise "missing-pin rehearsal unexpectedly resolved a managed Codex runtime"
      rescue
        error ->
          IO.puts(
            "KOGEN_PREPARE_RESULT\t" <>
              Jason.encode!(%{"class" => "environment", "reason" => Exception.message(error)})
          )

          System.halt(1)
      end
    else
      prepare!()
    end
  end

  defp trace_prepare do
    if path = System.get_env("KOGEN_REHEARSAL_TRACE") do
      File.write!(path, "Kogen.ManagedRuntimeReady.prepare!\n", [:append])
    end
  end

  @doc false
  def prepare!(installers) when is_map(installers) do
    codex = install!(Map.fetch!(installers, :codex), "Codex", @codex_version)
    claude = install!(Map.fetch!(installers, :claude_code), "Claude Code", @claude_code_version)
    %{codex: codex, claude_code: claude}
  end

  @doc "Read-only verification that both exact managed runtime pins are installed."
  def verify! do
    verify!(%{
      codex: &Kogen.Codex.installed/0,
      claude_code: &Kogen.ClaudeCode.installed/0
    })
  end

  @doc false
  def verify!(inspectors) when is_map(inspectors) do
    codex = inspect!(Map.fetch!(inspectors, :codex), "Codex", @codex_version)
    claude = inspect!(Map.fetch!(inspectors, :claude_code), "Claude Code", @claude_code_version)
    %{codex: codex, claude_code: claude}
  end

  defp install!(install, label, expected) when is_function(install, 0) do
    case install.() do
      {:ok, %{"version" => ^expected} = runtime} ->
        runtime

      {:ok, %{"version" => version}} ->
        raise "managed #{label} pin mismatch: expected #{expected}, got #{inspect(version)}"

      {:error, reason} ->
        raise "managed #{label} preparation failed: #{reason}"

      other ->
        raise "managed #{label} installer returned an invalid result: #{inspect(other)}"
    end
  end

  defp inspect!(inspector, label, expected) when is_function(inspector, 0) do
    case inspector.() do
      {:ok, %{"version" => ^expected} = runtime} ->
        runtime

      {:ok, %{"version" => version}} ->
        raise "managed #{label} pin mismatch: expected #{expected}, got #{inspect(version)}"

      {:error, reason} ->
        raise "managed #{label} verification failed: #{reason}"

      other ->
        raise "managed #{label} verification returned an invalid result: #{inspect(other)}"
    end
  end
end
