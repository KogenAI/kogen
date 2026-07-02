defmodule Mix.Tasks.Codegen.Loop do
  @shortdoc "Runs the deterministic orchestration loop for one pitch."

  @moduledoc """
  `mix codegen.loop --harness=<claude_code|pi> --stack=<phoenix|static> --cwd=<dir> <pitch>`

  Execs from the build-mode `dispatch.sh` path in place of a single
  self-orchestrating agent session. Runs `CodegenTestHarness.OrchestrationLoop.run/1`
  and exits:

  - `0` — cycle reached COMMITTED with a clear gate
  - non-zero, reason on stderr — any failure (crash loud; no silent success)

  ## Flags

  - `--harness` — required, `claude_code` | `pi`
  - `--stack` — required, `phoenix` | `static`
  - `--cwd` — required, project directory the loop operates in
  - `<pitch>` — required positional arg, the prompt/pitch text (or `@<path>`
    to read it from a file, matching `codegen-call`'s `@<path>` convention)
  """

  use Mix.Task

  alias CodegenTestHarness.OrchestrationLoop

  @impl Mix.Task
  def run(argv) do
    {opts, positional, invalid} =
      OptionParser.parse(argv,
        strict: [harness: :string, stack: :string, cwd: :string]
      )

    if invalid != [] do
      Mix.shell().error("codegen.loop: invalid flags: #{inspect(invalid)}")
      exit({:shutdown, 2})
    end

    harness = Keyword.get(opts, :harness) || missing_flag!("--harness")
    stack = Keyword.get(opts, :stack) || missing_flag!("--stack")
    cwd = Keyword.get(opts, :cwd) || missing_flag!("--cwd")

    pitch =
      case positional do
        [pitch_arg | _] -> resolve_pitch(pitch_arg, cwd)
        [] -> missing_flag!("<pitch>")
      end

    case OrchestrationLoop.run(harness: harness, stack: stack, cwd: cwd, pitch: pitch) do
      :ok ->
        Mix.shell().info("codegen.loop: COMMITTED, gate clear")

      {:error, reason} ->
        Mix.shell().error("codegen.loop: FAILED — #{reason}")
        exit({:shutdown, 1})
    end
  end

  @doc false
  @spec resolve_pitch(String.t(), String.t()) :: String.t()
  def resolve_pitch("@" <> path, cwd) do
    abs = Path.expand(path, cwd)

    unless File.exists?(abs) do
      Mix.shell().error("codegen.loop: pitch file not found at #{abs}")
      exit({:shutdown, 2})
    end

    File.read!(abs)
  end

  def resolve_pitch(literal, cwd) do
    abs = Path.expand(literal, cwd)

    if File.exists?(abs) do
      File.read!(abs)
    else
      literal
    end
  end

  defp missing_flag!(name) do
    Mix.shell().error("codegen.loop: #{name} is required")
    exit({:shutdown, 2})
  end
end
