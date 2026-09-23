defmodule Kogen.Harness do
  @moduledoc """
  The one harness interface used by Build, the Shape task and provider evidence.

  `.kogen/config.yaml` names the harness. `codex` selects managed native Codex
  (`Kogen.Harness.Codex`, unchanged behind this interface); `claude` selects
  the Kogen-managed Claude Code (`Kogen.Harness.Claude`). The adapter supplies
  runtime and login readiness, launch contexts, fresh and exactly resumed
  Developer turns, Reviewer verdicts and the interactive Shaper.

  A launch context carries its harness; contexts without one are Codex's, so
  existing Codex callers and fixtures keep their exact behavior.
  `Kogen.Check` and the Stop runner stay harness-independent.
  """
  use Boundary, deps: [Kogen.Codex, Kogen.ClaudeCode, Kogen.Intent]

  alias Kogen.Harness.{Claude, Codex}

  @doc "Selects the configured runtime and scope and checks readiness before any launch."
  def open(config, project \\ File.cwd!()) do
    case harness(config) do
      "claude" -> Kogen.ClaudeCode.open(config, project)
      _codex -> Kogen.Codex.open(config, project)
    end
  end

  @doc "Fresh launch settings for a held selection."
  def launch_context(%{harness: "claude"} = selection),
    do: Kogen.ClaudeCode.launch_context(selection)

  def launch_context(selection), do: Kogen.Codex.launch_context(selection)

  @doc "Releases a held selection."
  def close(%{harness: "claude"} = selection), do: Kogen.ClaudeCode.close(selection)
  def close(selection), do: Kogen.Codex.close(selection)

  @doc "Launches a fresh Developer turn with the prompt on stdin."
  def launch_developer(prompt, model, effort, policy_environment \\ [], context \\ nil),
    do: adapter(context).launch_developer(prompt, model, effort, policy_environment, context)

  @doc "Resumes the exact Developer session with the prompt on stdin."
  def resume_developer(session_id, text, model, effort, policy_environment \\ [], context \\ nil) do
    adapter(context).resume_developer(
      session_id,
      text,
      model,
      effort,
      policy_environment,
      context
    )
  end

  @doc "Launches a fresh Developer turn using the controller-supplied handoff schema."
  def launch_build_developer(
        prompt,
        model,
        effort,
        schema,
        policy_environment \\ [],
        context \\ nil
      ) do
    adapter(context).launch_build_developer(
      prompt,
      model,
      effort,
      schema,
      policy_environment,
      context
    )
  end

  @doc "Resumes the exact Developer session using the controller-supplied handoff schema."
  def resume_build_developer(
        session_id,
        text,
        model,
        effort,
        schema,
        policy_environment \\ [],
        context \\ nil
      ) do
    adapter(context).resume_build_developer(
      session_id,
      text,
      model,
      effort,
      schema,
      policy_environment,
      context
    )
  end

  @doc "Launches an independent Reviewer and requires a schema-valid Verdict."
  def launch_reviewer(prompt, model, effort, context \\ nil),
    do: adapter(context).launch_reviewer(prompt, model, effort, context)

  @doc "Launches the interactive Shaper with the caller's real terminal."
  def exec_shaper(model, effort, prompt_file, context \\ nil),
    do: adapter(context).exec_shaper(model, effort, prompt_file, context)

  @doc false
  def developer_args(model, effort, resume_session_id \\ nil),
    do: Codex.developer_args(model, effort, resume_session_id)

  @doc false
  def reviewer_args(model, effort), do: Codex.reviewer_args(model, effort)

  @doc false
  def shaper_args(model, effort, prompt_file), do: Codex.shaper_args(model, effort, prompt_file)

  @doc false
  def resolve_executable, do: Codex.resolve_executable()

  defp harness(config), do: Map.get(config, :harness, "codex")

  defp adapter(%{harness: "claude"}), do: Claude
  defp adapter(context) when is_map(context), do: Codex

  # Without a context the offline `KOGEN_HARNESS` fixture keeps Codex's
  # established route; otherwise the tracked configuration decides.
  defp adapter(nil) do
    with nil <- System.get_env("KOGEN_HARNESS"),
         {:ok, %{harness: "claude"}} <- Kogen.Intent.read_config() do
      Claude
    else
      _ -> Codex
    end
  end
end
