defmodule Kogen.E2e do
  @moduledoc false
  use Boundary,
    deps: [
      Kogen.Contracts,
      Kogen.Engine,
      Kogen.Kernel,
      Kogen.Proc,
      Kogen.State,
      Kogen.Testkit,
      Kogen.Workspace,
      ExUnit
    ],
    exports: [Build, Build.Fixture, Build.Options, Build.Result, ScriptedProvider]
end

defmodule Kogen.E2e.Build.Options do
  @moduledoc false

  @enforce_keys [:seed_project]
  defstruct [:seed_project, :move_base_on]

  @type t :: %__MODULE__{seed_project: Path.t(), move_base_on: atom() | nil}
end

defmodule Kogen.E2e.Build.Fixture do
  @moduledoc false

  @enforce_keys [:project_root, :origin, :approved_base, :approval_commit, :git_env]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          project_root: Path.t(),
          origin: Path.t(),
          approved_base: String.t(),
          approval_commit: String.t(),
          git_env: %{String.t() => String.t()}
        }
end

defmodule Kogen.E2e.Build.Result do
  @moduledoc false

  @enforce_keys [:build, :events, :fixture, :run_status, :claim_released]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          build: Kogen.Engine.Build.Result.t(),
          events: [Kogen.State.Event.t()],
          fixture: Kogen.E2e.Build.Fixture.t(),
          run_status: Kogen.State.Run.status(),
          claim_released: boolean()
        }
end

defmodule Kogen.E2e.Build do
  @moduledoc "Creates and runs a tiny approved project through the real Build engine."

  alias Kogen.Contracts.ProcResult
  alias Kogen.E2e.Build.Fixture
  alias Kogen.E2e.Build.Options
  alias Kogen.E2e.Build.Result
  alias Kogen.E2e.ScriptedProvider
  alias Kogen.E2e.ScriptedProvider.Config
  alias Kogen.Engine.Build.Request
  alias Kogen.Engine.Runtime
  alias Kogen.Kernel.Types.ApprovalPreview
  alias Kogen.Proc
  alias Kogen.Testkit.Git
  alias Kogen.Workspace

  @slug "build-engine"

  @spec prepare_seed!(Path.t()) :: Path.t()
  def prepare_seed!(parent) do
    seed = Path.join(parent, "compiled-tiny-project")
    origin = Path.join(parent, "approved-origin.git")
    write_seed!(seed)
    write_intent!(seed)
    compile_seed!(seed)
    prepare_approved_seed!(seed, origin)
    seed
  end

  @spec run!(Path.t(), [ScriptedProvider.Step.t()], Options.t()) :: Result.t()
  def run!(parent, steps, %Options{} = options) do
    fixture = create_fixture!(parent, options.seed_project)

    {:ok, server} =
      ScriptedProvider.start_link(steps, provider_hook(fixture, options.move_base_on))

    try do
      run_build!(fixture, server)
    after
      GenServer.stop(server, :normal)
    end
  end

  defp run_build!(%Fixture{} = fixture, server) do
    runtime = runtime!(fixture.project_root)

    request = %Request{
      slug: @slug,
      project_root: fixture.project_root,
      origin: fixture.origin,
      base: "main",
      model: "scripted-model",
      effort: "medium",
      runtime: runtime,
      provider_mod: ScriptedProvider,
      provider_config: %Config{server: server},
      credential_source: :custom
    }

    {:ok, build} = Kogen.Kernel.build(request)
    run = load_run!(fixture.project_root, build.run_id)

    %Result{
      build: build,
      events: read_events!(build.run_dir),
      fixture: fixture,
      run_status: run.status,
      claim_released: claim_released?(fixture, build.run_id)
    }
  end

  defp runtime!(project_root) do
    {:ok, discovered} = Kogen.Kernel.runtime()
    base_env = test_runtime_environment(discovered.base_env)
    fake_mise = write_fake_mise!(project_root, Map.fetch!(base_env, "PATH"))
    runtime = %{discovered | base_env: base_env, git_env: Git.env(), mise: fake_mise}

    case Kogen.Kernel.project_environment(project_root, runtime) do
      {:ok, env} -> Runtime.for_project(runtime, env)
      {:error, reason} -> raise "test fake mise failed: #{inspect(reason)}"
    end
  end

  defp test_runtime_environment(base_env) do
    allowed = ~w(PATH HOME LANG LC_ALL TERM TMPDIR USER SHELL MIX_HOME HEX_HOME)
    markers = ~w(KOGEN_ERTS_DIR KOGEN_ERTS_BIN KOGEN_ESCRIPT_DIR KOGEN_BIN_DIR)

    base_env
    |> Map.take(allowed ++ markers)
    |> Map.merge(Git.env())
  end

  defp write_fake_mise!(project_root, path_value) do
    path = Path.join([project_root, ".test-bin", "mise"])
    env = %{"PATH" => path_value, "MIX_ENV" => "test", "ERL_FLAGS" => "+S 1:1 +A 1"}
    json = env |> :json.encode() |> IO.iodata_to_binary()
    quoted_json = shell_quote(json)

    script = """
    #!/bin/sh
    if [ "$1" = "env" ]; then
      printf '%s\\n' #{quoted_json}
    else
      echo "test fake mise only supports env" >&2
      exit 64
    fi
    """

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, script)
    File.chmod!(path, 0o755)
    path
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp load_run!(project_root, run_id) do
    case Kogen.State.load(Path.join(project_root, ".kogen"), run_id) do
      {:ok, run} -> run
      {:error, reason} -> raise "test Build run is missing: #{inspect(reason)}"
    end
  end

  defp claim_released?(%Fixture{} = fixture, run_id) do
    case Workspace.ref_read(fixture.origin, "refs/kogen/claim", fixture.git_env) do
      {:error, :missing} -> true
      {:ok, _claim} -> false
      {:error, reason} -> raise "cannot inspect Build claim for #{run_id}: #{inspect(reason)}"
    end
  end

  defp create_fixture!(parent, seed_project) do
    project = Path.join(parent, "project")
    origin = Path.join(parent, "origin.git")
    git_env = Git.env()

    copy_seed!(seed_project, project)
    copy_origin!(seed_project, origin)
    _remote = Git.git!(project, ["remote", "set-url", "origin", origin])

    {:ok, base_sha} = Workspace.ref_read(origin, "refs/heads/main", git_env)
    {:ok, approval_commit} = Workspace.ref_read(origin, "refs/kogen/intents/#{@slug}", git_env)

    %Fixture{
      project_root: project,
      origin: origin,
      approved_base: base_sha,
      approval_commit: approval_commit,
      git_env: git_env
    }
  end

  defp copy_seed!(seed, project) do
    Git.copy_tree!(seed, project)
  end

  defp copy_origin!(seed_project, origin) do
    source = Path.join([Path.dirname(seed_project), "approved-origin.git"])
    Git.copy_tree!(source, origin)
  end

  defp prepare_approved_seed!(project, origin) do
    Git.bare!(origin)
    initialize_project!(project, origin)
    {:ok, _base_sha} = Workspace.ref_read(origin, "refs/heads/main", Git.env())

    {:ok, preview} =
      Kogen.Kernel.Approval.prepare(@slug, project, origin, "main", "Kogen Test", Git.env())

    {:ok, _approval_commit} = Kogen.Kernel.approve(%ApprovalPreview{} = preview)
    :ok
  end

  defp initialize_project!(project, origin) do
    _init = Git.git!(project, ["init", "--quiet", "--template="])
    _add = Git.git!(project, ["add", "--all"])
    _commit = Git.git!(project, ["commit", "--quiet", "-m", "Seed tiny project"])
    _branch = Git.git!(project, ["branch", "-M", "main"])
    _remote = Git.git!(project, ["remote", "add", "origin", origin])
    _push = Git.git!(project, ["push", "--quiet", "--set-upstream", "origin", "main"])
    _head = Git.git!(origin, ["symbolic-ref", "HEAD", "refs/heads/main"])
    :ok
  end

  defp write_intent!(project) do
    intent = """
    ---
    title: "Expose a ready value"
    domains: [kernel]
    size: small
    ---
    Make TinyApp.value/0 return the approved ready value.

    ## Acceptance
    - A1: TinyApp.value/0 returns :ready.

    ## Verify
    - A1: test

    ## Notes
    Keep the implementation inside lib/tiny_app.ex.
    """

    acceptance = """
    defmodule TinyApp.AcceptanceTest do
      use ExUnit.Case, async: true

      @tag intent: "build-engine/A1"
      test "returns the ready value" do
        assert TinyApp.value() == :ready
      end
    end
    """

    intent_path = Path.join([project, ".kogen", "intents", @slug, "intent.md"])
    acceptance_path = Path.join([project, ".kogen", "acceptance", "#{@slug}_test.exs"])

    File.mkdir_p!(Path.dirname(intent_path))
    File.mkdir_p!(Path.dirname(acceptance_path))
    File.write!(intent_path, intent)
    File.write!(acceptance_path, acceptance)
  end

  defp write_seed!(seed) do
    files = %{
      ".gitignore" => "_build/\ndeps/\n",
      "mix.exs" => mix_project(),
      ".kogen/project.yaml" => project_config(),
      "lib/tiny_app.ex" =>
        "defmodule TinyApp do\n  # revision: base\n  def value, do: :base\nend\n",
      "test/test_helper.exs" => "ExUnit.start()\n"
    }

    Enum.each(files, fn {relative, contents} ->
      path = Path.join(seed, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
    end)
  end

  defp compile_seed!(seed) do
    {:ok, runtime} = Kogen.Kernel.runtime()
    env = runtime.base_env |> Map.merge(Git.env()) |> Map.put("MIX_ENV", "test")
    mix = executable!(env, "mix")

    _output = command!([mix, "compile", "--warnings-as-errors"], cd: seed, env: env)
  end

  defp command!(argv, options) do
    case Proc.run(argv, options) do
      {:ok, %ProcResult{exit_status: 0, timed_out: false, output_tail: output}} -> output
      {:ok, %ProcResult{} = result} -> raise "test command failed: #{inspect(result)}"
      {:error, reason} -> raise "test command could not run: #{inspect(reason)}"
    end
  end

  defp executable!(env, name) do
    path = Map.fetch!(env, "PATH")

    case Enum.find_value(String.split(path, ":", trim: true), fn directory ->
           candidate = Path.join(directory, name)
           if executable_file?(candidate), do: candidate
         end) do
      nil -> raise "#{name} is unavailable; run the tests through mise exec"
      executable -> executable
    end
  end

  defp executable_file?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> :erlang.band(mode, 0o111) != 0
      {:error, _reason} -> false
    end
  end

  defp mix_project do
    """
    defmodule TinyApp.MixProject do
      use Mix.Project

      def project do
        [app: :tiny_app, version: "0.1.0", elixir: "~> 1.20", start_permanent: Mix.env() == :prod]
      end

      def application, do: [extra_applications: [:logger]]
    end
    """
  end

  defp project_config do
    """
    name: tiny_app
    checks:
      - name: source-present
        argv: [test, -s, lib/tiny_app.ex]
        timeout_ms: 60000
    fix: []
    domains:
      kernel: [lib]
    """
  end

  defp provider_hook(_fixture, nil), do: nil

  defp provider_hook(%Fixture{} = fixture, stage) do
    fn
      ^stage -> move_origin_base(fixture)
      _other -> :skip
    end
  end

  defp move_origin_base(%Fixture{} = fixture) do
    _commit =
      Git.git!(fixture.project_root, [
        "commit",
        "--quiet",
        "--allow-empty",
        "-m",
        "Advance base during Build"
      ])

    _push = Git.git!(fixture.project_root, ["push", "--quiet", "origin", "main"])
    :ok
  end

  defp read_events!(run_dir) do
    run_dir
    |> Path.join("events.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case Kogen.State.decode_event(line) do
        {:ok, event} -> event
        {:error, reason} -> raise "invalid test Build event: #{inspect(reason)}"
      end
    end)
  end
end
