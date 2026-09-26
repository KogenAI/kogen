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
  helper; `expert_environment/3` carries the frozen Expert assignment.

  Every open takes the control project explicitly. A Build also passes a
  launch (`:root` the Candidate, `:control`, `:harness_home`, the write
  boundary's argv `:prefix`, `:env` and `:tmp_dir`, and `:bindings`, the
  login binding of each harness resolved once from the control root at
  admission): every launch of that Build, readiness included, then runs with
  the Candidate as its cwd, inside the boundary, with the bound scope.
  """
  use Boundary, deps: [Kogen.Codex, Kogen.ClaudeCode, Kogen.Intent]

  alias Kogen.Harness.{Claude, Codex}

  @expert_variable "KOGEN_EXPERT"

  @doc """
  Opens readiness for the resolved route's harness only, before any launch.
  `project` is the control checkout; `launch` is a Build launch or `nil`.
  """
  def open(config, project, launch \\ nil) do
    case harness(config) do
      {:ok, "claude"} -> Kogen.ClaudeCode.open(config, project, harness_launch(launch, "claude"))
      {:ok, "codex"} -> Kogen.Codex.open(config, project, harness_launch(launch, "codex"))
      {:error, reason} -> {:error, reason}
    end
  end

  defp harness_launch(nil, _harness), do: nil

  defp harness_launch(launch, harness) do
    case launch do
      %{bindings: %{^harness => binding}} -> Map.put(launch, :binding, binding)
      _ -> launch
    end
  end

  @doc """
  Resolves, once and without any login check, the login binding (runtime and
  scope) of every harness assigned to `roles`, from the control `project`.
  """
  def bindings(config, roles, project) do
    roles
    |> Enum.group_by(&Kogen.Intent.role_harness(config, &1))
    |> Enum.sort_by(fn {_harness, assigned} ->
      Enum.find_index(roles, &(&1 == hd(assigned)))
    end)
    |> Enum.reduce_while({:ok, %{}}, fn {harness, assigned}, {:ok, acc} ->
      case bind(harness, project) do
        {:ok, binding} ->
          {:cont, {:ok, Map.put(acc, harness, binding)}}

        {:error, reason} ->
          {:halt, {:error, "#{role_names(assigned)} harness #{harness} is not ready: #{reason}"}}
      end
    end)
  end

  defp bind(harness, project) do
    case harness(%{harness: harness}) do
      {:ok, "claude"} -> Kogen.ClaudeCode.bind(project)
      {:ok, "codex"} -> Kogen.Codex.bind(project)
      {:error, _reason} = error -> error
    end
  end

  @doc "The recorded form of a binding: harness, scope name and path, runtime version."
  def binding_record(%{harness: harness, runtime: runtime, scope: scope}) do
    %{
      "harness" => harness,
      "scope_name" => scope && Atom.to_string(scope.name),
      "scope_path" => scope && scope.path,
      "runtime_version" => runtime["version"],
      "runtime_executable" => runtime["executable"]
    }
  end

  @doc "A binding from its recorded form (the inverse of `binding_record/1`)."
  def binding_from_record(%{"harness" => harness} = record) do
    scope =
      if is_binary(record["scope_path"]),
        do: %{name: String.to_existing_atom(record["scope_name"]), path: record["scope_path"]}

    %{
      harness: harness,
      runtime: %{
        "executable" => record["runtime_executable"],
        "version" => record["runtime_version"]
      },
      scope: scope
    }
  end

  @doc """
  Opens readiness for every harness assigned to `roles`, in role order, before
  any launch. Each harness is opened once with its native configuration. A
  harness that is not ready fails with the roles assigned to it and that
  harness named; selections already held are released, and no role falls back
  to another harness.
  """
  def open_roles(config, roles, project, launch \\ nil)

  def open_roles(config, roles, project, launch) do
    roles
    |> Enum.group_by(&Kogen.Intent.role_harness(config, &1))
    |> Enum.sort_by(fn {_harness, assigned} ->
      Enum.find_index(roles, &(&1 == hd(assigned)))
    end)
    |> Enum.reduce_while({:ok, %{}}, &open_assigned(config, project, launch, &1, &2))
    |> case do
      {:ok, selections} ->
        {:ok, %{route: config, roles: roles, selections: selections, launch: launch}}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  The interactive Shape task's form, outside any Build: its project is the
  checkout it runs in. A Build always passes its control root and launch.
  """
  def open_roles(config, roles), do: open_roles(config, roles, File.cwd!(), nil)

  defp open_assigned(config, project, launch, {harness, assigned}, {:ok, selections}) do
    case open(Kogen.Intent.harness_config(config, harness), project, launch) do
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
  def role_context(%{route: config, selections: selections, roles: roles} = runtime, role) do
    unless role in roles, do: raise(ArgumentError, "role #{role} was not opened for this session")
    harness = Kogen.Intent.role_harness(config, role)
    context = launch_context(Map.fetch!(selections, harness))
    %{context | env: context.env ++ expert_environment(config, role, Map.get(runtime, :launch))}
  end

  @doc """
  The Expert assignment a role's launch carries. When the route assigns the
  Expert to another harness than `role`, `KOGEN_EXPERT` holds the frozen
  Expert harness, model, effort and that harness's native helpers for
  `mix kogen.expert`; otherwise it is removed, so no inherited assignment
  leaks into a launch. Inside a Build (`launch`), the assignment also carries
  the control root, the Candidate path, the harness home, the Build's binding
  for the Expert's harness and the write boundary's grant inputs and sha256,
  so `mix kogen.expert` launches from the Candidate with that bound scope and
  that harness home, inside the Build's boundary.
  """
  def expert_environment(config, role, launch \\ nil) do
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

      [
        {@expert_variable,
         Jason.encode!(Map.merge(assignment, build_assignment(launch, expert_harness)))}
      ]
    else
      [{@expert_variable, nil}]
    end
  end

  defp build_assignment(nil, _harness), do: %{}

  defp build_assignment(launch, harness) do
    %{
      "control_root" => launch.control,
      "candidate" => launch.root,
      "harness_home" => launch.harness_home,
      "binding" => binding_record(Map.fetch!(launch.bindings, harness)),
      "write_boundary" => launch.boundary
    }
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
