defmodule Mix.Tasks.Kogen.Shape do
  use Mix.Task
  use Boundary, deps: [Kogen.Intent, Kogen.Harness, Kogen.Git, Mix]

  @shortdoc "Mints a UUIDv7 and execs the interactive Shaping Controller TUI"
  @moduledoc """
  Reads the tracked `.kogen/config.yaml`, mints a fresh UUIDv7, renders the
  Shaping Controller prompt from `priv/kogen/prompts/shaping.md`, and launches interactive `codex`
  attached to this terminal as the interactive Shaping Controller. Kogen performs no
  validation of what the Shaping Controller produces.
  """

  @prompt_path "priv/kogen/prompts/shaping.md"

  @impl Mix.Task
  def run(_args) do
    case Kogen.Intent.read_config() do
      {:ok, config} -> shape(config)
      {:error, reason} -> fail(reason)
    end
  end

  defp shape(config) do
    id = Kogen.Intent.mint_uuid7()
    IO.puts(id)

    branch =
      case Kogen.Git.current_branch() do
        {:ok, branch} -> branch
        {:error, reason} -> fail(reason)
      end

    {:ok, head} = Kogen.Git.head_sha()

    prompt_file = Path.join(System.tmp_dir!(), "kogen-shaping-prompt-#{id}.md")

    @prompt_path
    |> File.read!()
    |> String.replace("{{id}}", id)
    |> String.replace("{{branch}}", branch)
    |> String.replace("{{head}}", head)
    |> then(&File.write!(prompt_file, &1))

    status = Kogen.Harness.exec_shaper(config.shaping.model, config.shaping.effort, prompt_file)
    File.rm(prompt_file)
    System.halt(status)
  end

  defp fail(reason) do
    IO.puts(:stderr, reason)
    System.halt(1)
  end
end
