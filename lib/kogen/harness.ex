defmodule Kogen.Harness do
  @moduledoc """
  The one harness interface used by Build, the Shape task and provider evidence.

  The session's resolved route (see `Kogen.Intent.read_config/2`) names its
  harness. `codex` selects managed native Codex (`Kogen.Harness.Codex`);
  `claude` selects the Kogen-managed Claude Code (`Kogen.Harness.Claude`). The
  adapter supplies runtime and login readiness, launch contexts, fresh and
  exactly resumed Developer turns, Reviewer verdicts and the interactive Shaper.

  Every selection and launch context carries its harness explicitly, and
  dispatch accepts only `claude` and `codex`: a missing or unknown harness
  fails loudly. Every launch takes the session's launch context; nothing here
  re-reads configuration. `Kogen.Check` and the Stop runner stay
  harness-independent.
  """
  use Boundary, deps: [Kogen.Codex, Kogen.ClaudeCode, Kogen.Intent]

  alias Kogen.Harness.{Claude, Codex}

  @doc "Opens readiness for the resolved route's harness only, before any launch."
  def open(config, project \\ File.cwd!()) do
    case harness(config) do
      {:ok, "claude"} -> Kogen.ClaudeCode.open(config, project)
      {:ok, "codex"} -> Kogen.Codex.open(config, project)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Fresh launch settings for a held selection."
  def launch_context(selection) do
    case adapter!(selection) do
      Claude -> Kogen.ClaudeCode.launch_context(selection)
      Codex -> Kogen.Codex.launch_context(selection)
    end
  end

  @doc "Releases a held selection."
  def close(selection) do
    case adapter!(selection) do
      Claude -> Kogen.ClaudeCode.close(selection)
      Codex -> Kogen.Codex.close(selection)
    end
  end

  @doc "Launches a fresh Developer turn with the prompt on stdin."
  def launch_developer(prompt, model, effort, policy_environment, context),
    do: adapter!(context).launch_developer(prompt, model, effort, policy_environment, context)

  @doc "Resumes the exact Developer session with the prompt on stdin."
  def resume_developer(session_id, text, model, effort, policy_environment, context) do
    adapter!(context).resume_developer(
      session_id,
      text,
      model,
      effort,
      policy_environment,
      context
    )
  end

  @doc """
  Launches a fresh Build Developer turn. It carries no handoff schema and
  returns the settled session with its final message (possibly empty) as the
  Developer's unverified notes.
  """
  def launch_build_developer(prompt, model, effort, policy_environment, context) do
    adapter!(context).launch_build_developer(prompt, model, effort, policy_environment, context)
  end

  @doc "Resumes the exact Build Developer session; like `launch_build_developer/5`."
  def resume_build_developer(session_id, text, model, effort, policy_environment, context) do
    adapter!(context).resume_build_developer(
      session_id,
      text,
      model,
      effort,
      policy_environment,
      context
    )
  end

  @doc "Launches an independent Reviewer and requires a schema-valid Verdict."
  def launch_reviewer(prompt, model, effort, context),
    do: adapter!(context).launch_reviewer(prompt, model, effort, context)

  @doc "Launches the interactive Shaper with the caller's real terminal."
  def exec_shaper(model, effort, prompt_file, context),
    do: adapter!(context).exec_shaper(model, effort, prompt_file, context)

  @doc false
  def developer_args(model, effort, resume_session_id \\ nil),
    do: Codex.developer_args(model, effort, resume_session_id)

  @doc false
  def reviewer_args(model, effort), do: Codex.reviewer_args(model, effort)

  @doc false
  def shaper_args(model, effort, prompt_file), do: Codex.shaper_args(model, effort, prompt_file)

  defp harness(%{harness: harness}) when harness in ["claude", "codex"], do: {:ok, harness}

  defp harness(%{harness: harness}),
    do: {:error, "unsupported harness: #{inspect(harness)}; expected codex or claude"}

  defp harness(_config),
    do: {:error, "harness selection has no harness; expected codex or claude"}

  defp adapter!(context) do
    case harness(context) do
      {:ok, "claude"} -> Claude
      {:ok, "codex"} -> Codex
      {:error, reason} -> raise ArgumentError, reason
    end
  end
end
