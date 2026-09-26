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

  A route assigns each role (`shaping`, `developer`, `reviewer`, `expert`) a
  harness. `open_roles/3` holds one selection per harness those roles use and
  `role_context/2` launches each role only through its assigned harness, with
  that harness's native helpers. A role whose Expert runs on another harness
  reaches it through `mix kogen.expert`, never through a substituted native
  helper; `expert_environment/2` carries the frozen Expert assignment.
  """
  use Boundary, deps: [Kogen.Codex, Kogen.ClaudeCode, Kogen.Intent]

  alias Kogen.Harness.{Claude, Codex}

  @expert_variable "KOGEN_EXPERT"

  @doc "Opens readiness for the resolved route's harness only, before any launch."
  def open(config, project \\ File.cwd!()) do
    case harness(config) do
      {:ok, "claude"} -> Kogen.ClaudeCode.open(config, project)
      {:ok, "codex"} -> Kogen.Codex.open(config, project)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Opens readiness for every harness assigned to `roles`, in role order, before
  any launch. Each harness is opened once with its native configuration. A
  harness that is not ready fails with the roles assigned to it and that
  harness named; selections already held are released, and no role falls back
  to another harness.
  """
  def open_roles(config, roles, project \\ File.cwd!()) do
    roles
    |> Enum.group_by(&Kogen.Intent.role_harness(config, &1))
    |> Enum.sort_by(fn {_harness, assigned} ->
      Enum.find_index(roles, &(&1 == hd(assigned)))
    end)
    |> Enum.reduce_while({:ok, %{}}, &open_assigned(config, project, &1, &2))
    |> case do
      {:ok, selections} -> {:ok, %{route: config, roles: roles, selections: selections}}
      {:error, _reason} = error -> error
    end
  end

  defp open_assigned(config, project, {harness, assigned}, {:ok, selections}) do
    case open(Kogen.Intent.harness_config(config, harness), project) do
      {:ok, selection} ->
        {:cont, {:ok, Map.put(selections, harness, selection)}}

      {:error, reason} ->
        close(%{selections: selections})
        {:halt, {:error, "#{role_names(assigned)} harness #{harness} is not ready: #{reason}"}}
    end
  end

  @doc """
  Fresh launch settings for `role` from its assigned harness's held selection,
  carrying the role's Expert assignment. A role outside the opened set fails.
  """
  def role_context(%{route: config, selections: selections, roles: roles}, role) do
    unless role in roles, do: raise(ArgumentError, "role #{role} was not opened for this session")
    harness = Kogen.Intent.role_harness(config, role)
    context = launch_context(Map.fetch!(selections, harness))
    %{context | env: context.env ++ expert_environment(config, role)}
  end

  @doc """
  The Expert assignment a role's launch carries. When the route assigns the
  Expert to another harness than `role`, `KOGEN_EXPERT` holds the frozen
  Expert harness, model, effort and that harness's native helpers for
  `mix kogen.expert`; otherwise it is removed, so no inherited assignment
  leaks into a launch.
  """
  def expert_environment(config, role) do
    expert_harness = Kogen.Intent.role_harness(config, :expert)

    if role != :expert and
         Kogen.Intent.role_harness(config, role) != expert_harness do
      expert = Kogen.Intent.harness_config(config, expert_harness)

      assignment = %{
        "route" => config.route,
        "caller" => Atom.to_string(role),
        "harness" => expert_harness,
        "model" => config.expert.model,
        "effort" => config.expert.effort,
        "helpers" =>
          Map.new(Map.take(expert.helpers, [:scout, :worker]), fn {label, profile} ->
            {Atom.to_string(label), %{"model" => profile.model, "effort" => profile.effort}}
          end)
      }

      [{@expert_variable, Jason.encode!(assignment)}]
    else
      [{@expert_variable, nil}]
    end
  end

  @doc "The environment variable carrying a cross-harness Expert assignment."
  def expert_variable, do: @expert_variable

  defp role_names(roles), do: Enum.map_join(roles, " and ", &Atom.to_string/1)

  @doc "Fresh launch settings for a held selection."
  def launch_context(selection) do
    case adapter!(selection) do
      Claude -> Kogen.ClaudeCode.launch_context(selection)
      Codex -> Kogen.Codex.launch_context(selection)
    end
  end

  @doc "Releases a held selection, or every selection of `open_roles/3`."
  def close(%{selections: selections}) do
    Enum.each(selections, fn {_harness, selection} -> close(selection) end)
  end

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

  @doc """
  Launches an independent Reviewer and requires a schema-valid Verdict. The
  verdict schema is chosen per launch: a context carrying `:ledger_paths` (the
  verification-surface ledger in the Reviewer's packet, see
  `with_ledger/2`) adds a required `ledger`; without one the schema is
  exactly `Kogen.Harness.Verdict.schema/0`.
  """
  def launch_reviewer(prompt, model, effort, context),
    do: adapter!(context).launch_reviewer(prompt, model, effort, context)

  @doc "A Reviewer launch context whose verdict must disposition `ledger_paths`."
  def with_ledger(context, ledger_paths) when is_map(context) and is_list(ledger_paths),
    do: Map.put(context, :ledger_paths, ledger_paths)

  @doc "The verification-surface ledger paths a launch context requests."
  def ledger_paths(context) when is_map(context), do: Map.get(context, :ledger_paths, [])
  def ledger_paths(_context), do: []

  @doc """
  Launches a fresh, read-only Expert for one question on stdin and returns its
  session and final message. It never resumes and never falls back.
  """
  def launch_expert(prompt, model, effort, context),
    do: adapter!(context).launch_expert(prompt, model, effort, context)

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
