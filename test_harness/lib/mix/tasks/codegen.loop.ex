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

  alias CodegenTestHarness.LoopQueue
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

    pitch_arg =
      case positional do
        [pitch_arg | _] -> pitch_arg
        [] -> missing_flag!("<pitch>")
      end

    pitch = resolve_pitch(pitch_arg, cwd)
    source = resolve_pitch_source(pitch_arg, cwd)

    slug =
      case source do
        {:file, abs} -> Path.basename(abs, ".md")
        :literal -> "adhoc"
      end

    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")
    cycle_id = "#{stamp}_#{slug}"

    result =
      OrchestrationLoop.run(
        harness: harness,
        stack: stack,
        cwd: cwd,
        pitch: pitch,
        cycle_id: cycle_id,
        slug: slug
      )

    # Emit aggregated per-cycle telemetry as a parseable stream-json result line
    # (benchmark instrumentation) regardless of outcome — a failed cycle still
    # spent tokens and its cost belongs in the A/B.
    emit_loop_telemetry(result)

    case result do
      :ok ->
        Mix.shell().info("codegen.loop: COMMITTED, gate clear")
        maybe_ship_pitch(source, cwd)

      {:error, reason} ->
        Mix.shell().error("codegen.loop: FAILED — #{reason}")
        exit({:shutdown, 1})
    end
  end

  @doc false
  def emit_loop_telemetry(result) do
    t = OrchestrationLoop.get_telemetry()

    subtype = if result == :ok, do: "success", else: "error"

    per_role =
      Map.new(t.per_role, fn {role, entries} ->
        summed =
          Enum.reduce(
            entries,
            %{cost_usd: 0.0, input_tokens: 0, output_tokens: 0, num_turns: 0},
            fn e, acc ->
              %{
                cost_usd: acc.cost_usd + e.cost_usd,
                input_tokens: acc.input_tokens + e.input_tokens,
                output_tokens: acc.output_tokens + e.output_tokens,
                num_turns: acc.num_turns + e.num_turns
              }
            end
          )

        {role, Map.put(summed, :calls, length(entries))}
      end)

    line =
      Jason.encode!(%{
        "type" => "result",
        "subtype" => subtype,
        "engine" => "elixir_loop",
        "num_turns" => t.num_turns,
        "total_cost_usd" => t.cost_usd,
        "terminal_reason" => if(result == :ok, do: "loop_committed", else: "loop_failed"),
        "role_calls" => t.role_calls,
        "usage" => %{
          "input_tokens" => t.input_tokens,
          "output_tokens" => t.output_tokens,
          "cache_read_input_tokens" => t.cache_read_tokens,
          "cache_creation_input_tokens" => t.cache_creation_tokens
        },
        "per_role" => per_role
      })

    IO.puts(line)
  end

  @doc false
  @spec resolve_pitch(String.t(), String.t()) :: String.t()
  def resolve_pitch("@" <> path, cwd) do
    abs = Path.expand(path, cwd)

    unless File.exists?(abs) do
      Mix.shell().error("codegen.loop: pitch file not found at #{abs}")
      exit({:shutdown, 2})
    end

    abs
    |> File.read!()
    |> LoopQueue.strip_frontmatter()
  end

  def resolve_pitch(literal, cwd) do
    abs = Path.expand(literal, cwd)

    if File.exists?(abs) do
      abs
      |> File.read!()
      |> LoopQueue.strip_frontmatter()
    else
      literal
    end
  end

  @doc false
  @spec resolve_pitch_source(String.t(), String.t()) :: {:file, String.t()} | :literal
  def resolve_pitch_source("@" <> path, cwd) do
    abs = Path.expand(path, cwd)
    if File.exists?(abs), do: {:file, abs}, else: :literal
  end

  def resolve_pitch_source(literal, cwd) do
    abs = Path.expand(literal, cwd)
    if File.exists?(abs), do: {:file, abs}, else: :literal
  end

  @doc false
  @spec maybe_ship_pitch({:file, String.t()} | :literal, String.t()) :: :ok
  def maybe_ship_pitch(:literal, _cwd), do: :ok

  def maybe_ship_pitch({:file, abs}, cwd) do
    ready_dir = Path.join([cwd, "codegen", "pitches", "ready"])
    name = Path.basename(abs)
    src_in_ready = Path.join(ready_dir, name)

    if Path.expand(abs) == Path.expand(src_in_ready) do
      shipped_dir = Path.join([cwd, "codegen", "pitches", "shipped"])
      ship_ready_pitch(src_in_ready, Path.join(shipped_dir, name), cwd)
    else
      :ok
    end
  end

  defp missing_flag!(name) do
    Mix.shell().error("codegen.loop: #{name} is required")
    exit({:shutdown, 2})
  end

  defp ship_ready_pitch(src, dst, cwd) do
    cond do
      not File.exists?(src) and File.exists?(dst) ->
        :ok

      true ->
        assert_clean_tree!(cwd)
        File.mkdir_p!(Path.dirname(dst))
        File.rename!(src, dst)
        :ok
    end
  end

  defp assert_clean_tree!(cwd) do
    case System.cmd("git", ["-C", cwd, "rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {_out, 0} ->
        {status, _} =
          System.cmd("git", ["-C", cwd, "status", "--porcelain"], stderr_to_stdout: true)

        if String.trim(status) != "" do
          raise "codegen.loop: refusing to ship — working tree not clean:\n#{status}"
        end

        :ok

      # not a git repo / git unavailable — fail open (mirrors legacy clean-tree-before-ship.sh)
      {_out, _nonzero} ->
        :ok
    end
  end
end
