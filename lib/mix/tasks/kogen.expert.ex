defmodule Mix.Tasks.Kogen.Expert do
  use Mix.Task

  use Boundary, deps: [Kogen.Build, Kogen.Harness, Kogen.ExecutionPolicy, Mix]

  alias Kogen.Build.{Workspace, WriteBoundary}

  @shortdoc "Consults the route's Expert on its assigned harness (run by a Kogen role)"
  @moduledoc """
  `mix kogen.expert < question` launches one fresh, read-only Expert for the
  question on stdin and prints its final answer.

  Only a Kogen role whose route assigns the Expert to another harness can run
  it: that role's launch carries the frozen Expert assignment (harness, model,
  effort and that harness's native helpers) in `KOGEN_EXPERT`. The task never
  reads `.kogen/config.yaml`, never substitutes another harness, model or
  effort, and fails naming the Expert role and harness when that harness is
  not ready or the launch fails.

  Inside a Build the assignment also names the control root, the Candidate,
  the harness home, the Build's login binding for the Expert's harness and
  the write boundary. The task then refuses any cwd other than that
  Candidate, launches the Expert with the Candidate as cwd, the bound scope
  (never one re-resolved) and its operation root or config dir under the
  harness home, takes no Codex lease (the Build controller holds it) and
  runs inside the Build's boundary: `inherited` when the kernel reports this
  process is already confined by it, otherwise the same grants applied anew.
  """

  @prompt_path "priv/kogen/prompts/expert.md"

  @impl Mix.Task
  def run(args) do
    with {:ok, config} <- assignment(System.get_env(Kogen.Harness.expert_variable())),
         {:ok, question} <- question(args),
         {:ok, project, launch} <- build_launch(config) do
      consult(config, question, project, launch)
    else
      {:error, reason} -> fail(reason)
    end
  end

  @doc false
  def assignment(nil),
    do:
      {:error,
       "mix kogen.expert: missing #{Kogen.Harness.expert_variable()} assignment; this role has no cross-harness Expert, so use its native expert helper"}

  def assignment(json) do
    with {:ok, %{} = data} <- Jason.decode(json),
         {:ok, harness} when harness in ["claude", "codex"] <- field(data, "harness"),
         {:ok, route} <- field(data, "route"),
         {:ok, caller} <- field(data, "caller"),
         {:ok, expert} <- profile(data),
         {:ok, helpers} <- helpers(data),
         {:ok, build} <- build(data, harness) do
      {:ok,
       %{
         route: route,
         caller: caller,
         harness: harness,
         expert: expert,
         helpers: helpers,
         roles: %{expert: harness},
         native_helpers: %{harness => helpers},
         build: build
       }}
    else
      _invalid ->
        {:error, "mix kogen.expert: invalid #{Kogen.Harness.expert_variable()} assignment"}
    end
  end

  defp field(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _missing -> :error
    end
  end

  defp profile(data) do
    with {:ok, model} <- field(data, "model"),
         {:ok, effort} <- field(data, "effort"),
         do: {:ok, %{model: model, effort: effort}}
  end

  defp helpers(%{"helpers" => %{"scout" => scout, "worker" => worker}})
       when is_map(scout) and is_map(worker) do
    with {:ok, scout} <- profile(scout),
         {:ok, worker} <- profile(worker),
         do: {:ok, %{scout: scout, worker: worker}}
  end

  defp helpers(_data), do: :error

  # Outside a Build the assignment carries no Build fields.
  defp build(data, harness) do
    case Map.take(data, ["control_root", "candidate", "harness_home", "binding", "write_boundary"]) do
      empty when map_size(empty) == 0 ->
        {:ok, nil}

      %{
        "control_root" => control,
        "candidate" => candidate,
        "harness_home" => home,
        "binding" => %{"harness" => ^harness} = binding,
        "write_boundary" => %{"sha256" => sha} = boundary
      }
      when is_binary(control) and is_binary(candidate) and is_binary(home) and is_binary(sha) ->
        {:ok,
         %{
           control: control,
           candidate: candidate,
           harness_home: home,
           binding: binding,
           boundary: boundary
         }}

      _partial ->
        :error
    end
  end

  @doc """
  The project and Build launch of an Expert consultation: outside a Build,
  the cwd and no launch; inside one, the recorded control root and a launch
  bound to the Build's Candidate, harness home, login binding and boundary.
  """
  def build_launch(%{build: nil}), do: {:ok, File.cwd!(), nil}

  def build_launch(%{build: build, harness: harness}) do
    cwd = Workspace.canonical(File.cwd!())

    with :ok <- candidate_cwd(cwd, build.candidate),
         {:ok, boundary} <- boundary(build) do
      record_launch(build, boundary, harness)

      {:ok, build.control,
       %{
         root: build.candidate,
         control: build.control,
         harness_home: build.harness_home,
         tmp_dir: boundary.grants.tmp_dir,
         prefix: WriteBoundary.prefix(boundary),
         env:
           WriteBoundary.environment(boundary) ++
             [{"KOGEN_HARNESS_HOME", build.harness_home}] ++
             Enum.map(~w(MIX_BUILD_PATH MIX_DEPS_PATH MIX_EXS), &{&1, nil}),
         bindings: %{harness => Kogen.Harness.binding_from_record(build.binding)},
         lease: false
       }}
    end
  end

  defp candidate_cwd(cwd, candidate) do
    if cwd == candidate,
      do: :ok,
      else:
        {:error,
         "mix kogen.expert: run it from the Build's Candidate #{candidate}; the current directory is #{cwd}"}
  end

  # Confinement comes from the kernel, never from the environment: inside
  # the Build's own profile the Expert inherits it; unconfined, the same
  # grants are applied anew; a foreign sandbox is refused.
  defp boundary(build) do
    input = %{
      candidate: build.boundary["candidate"],
      harness_home: build.boundary["harness_home"],
      tmp_dir: build.boundary["tmp_dir"],
      control: build.boundary["control"],
      claude_scope: build.boundary["claude_scope"],
      codex_scope: build.boundary["codex_scope"]
    }

    case WriteBoundary.confinement() do
      {:ok, :unconfined} ->
        WriteBoundary.prepare(input)

      {:ok, :confined} ->
        case System.get_env(WriteBoundary.marker()) do
          marker when is_binary(marker) and marker != "" ->
            {:ok, WriteBoundary.inherited(marker, input)}

          _ ->
            {:error,
             "mix kogen.expert: this process is confined by a foreign sandbox, not a Kogen Build boundary"}
        end

      {:error, _reason} = error ->
        error
    end
  end

  # The Expert's launch record: its boundary mode, in the harness home's
  # raw-log directory the controller copies at Build exit.
  defp record_launch(build, boundary, harness) do
    directory = Path.join(build.harness_home, "raw-log")

    line =
      Jason.encode!(%{
        "role" => "expert",
        "harness" => harness,
        "boundary" => boundary.mode,
        "profile_sha256" => boundary.sha256,
        "cwd" => build.candidate
      })

    with :ok <- File.mkdir_p(directory),
         do: File.write(Path.join(directory, "expert-launches.jsonl"), line <> "\n", [:append])
  end

  defp question([]) do
    case IO.read(:stdio, :eof) do
      text when is_binary(text) -> nonblank(text)
      _eof -> {:error, "mix kogen.expert: provide one question on stdin"}
    end
  end

  defp question(args), do: nonblank(Enum.join(args, " "))

  defp nonblank(text) do
    if String.trim(text) == "",
      do: {:error, "mix kogen.expert: provide one question on stdin"},
      else: {:ok, text}
  end

  defp consult(config, question, project, launch) do
    case launch(config, question, project, launch) do
      {:ok, %{message: message}} -> IO.puts(message)
      {:error, reason} -> fail(reason)
    end
  end

  @doc """
  Opens the assigned Expert harness, launches one fresh Expert with the
  rendered Expert prompt and releases the selection. Returns the Expert's
  session and final message, or an error naming the Expert role and harness.
  """
  def launch(config, question, project, launch \\ nil) do
    case Kogen.Harness.open(config, project, launch) do
      {:ok, selection} ->
        try do
          launch_selected(config, question, selection)
        after
          Kogen.Harness.close(selection)
        end

      {:error, reason} ->
        {:error, "expert harness #{config.harness} is not ready: #{reason}"}
    end
  end

  defp launch_selected(config, question, selection) do
    label =
      "expert on harness #{config.harness} (#{config.expert.model} at #{config.expert.effort})"

    prompt =
      File.read!(@prompt_path)
      |> String.replace("{{caller}}", config.caller)
      |> String.replace("{{route}}", config.route)
      |> String.replace("{{execution_policy}}", Kogen.ExecutionPolicy.render(config, "expert"))
      |> String.replace("{{question}}", question)

    context = Kogen.Harness.launch_context(selection)

    case Kogen.Harness.launch_expert(prompt, config.expert.model, config.expert.effort, context) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, "#{label} failed: #{inspect(reason)}"}
    end
  rescue
    error -> {:error, "expert on harness #{config.harness} failed: #{Exception.message(error)}"}
  end

  defp fail(reason) do
    IO.puts(:stderr, reason)
    System.halt(1)
  end
end
