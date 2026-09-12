defmodule Mix.Tasks.Kogen.Shape do
  use Mix.Task
  use Boundary, deps: [Kogen.Intent, Kogen.Harness, Kogen.Git, Kogen.ExecutionPolicy, Mix]

  @shortdoc "Starts fresh shaping or continues an existing draft in a new conversation"
  @moduledoc """
  `mix kogen.shape` mints a new Intent. `mix kogen.shape <draft-slug>` opens
  an existing draft in a fresh interactive conversation using current configuration.
  Launch never rewrites the selected draft or restores a previous session.
  """

  @prompt_path "priv/kogen/prompts/shaping.md"

  @impl Mix.Task
  def run(args) do
    with {:ok, selection} <- select(args),
         {:ok, config} <- Kogen.Intent.read_config() do
      shape(config, selection)
    else
      {:error, reason} -> fail(reason)
    end
  end

  defp select([]), do: {:ok, nil}
  defp select([slug]), do: Kogen.Intent.read_draft(slug)
  defp select(_args), do: {:error, "usage: mix kogen.shape [draft-slug]"}

  defp shape(config, selection) do
    with {:ok, branch} <- Kogen.Git.current_branch(),
         {:ok, head} <- Kogen.Git.head_sha() do
      launch(config, selection, branch, head)
    else
      {:error, reason} -> fail(reason)
    end
  end

  defp launch(config, selection, branch, head) do
    id = if selection, do: selection.id, else: Kogen.Intent.mint_uuid7()
    IO.puts(id)
    started = DateTime.utc_now() |> DateTime.to_iso8601()
    baseline = if selection, do: selection.baseline, else: %{"branch" => branch, "head" => head}
    mode = if selection, do: "continuation", else: "fresh"
    startup = File.read!("priv/kogen/prompts/shaping-#{mode}.md")

    prompt_file =
      Path.join(System.tmp_dir!(), "kogen-shaping-prompt-#{Kogen.Intent.mint_uuid7()}.md")

    replacements = %{
      "id" => id,
      "branch" => baseline["branch"],
      "head" => baseline["head"],
      "checkout_branch" => branch,
      "checkout_head" => head,
      "slug" => if(selection, do: selection.slug, else: "<slug>"),
      "harness" => config.harness,
      "model" => config.shaping.model,
      "effort" => config.shaping.effort,
      "started" => started
    }

    prompt = File.read!(@prompt_path) |> String.replace("{{startup}}", startup)

    prompt =
      Enum.reduce(replacements, prompt, fn {key, value}, text ->
        String.replace(text, "{{#{key}}}", value)
      end)

    File.write!(
      prompt_file,
      String.replace(
        prompt,
        "{{execution_policy}}",
        Kogen.ExecutionPolicy.render(config, "shaping")
      )
    )

    status = Kogen.Harness.exec_shaper(config.shaping.model, config.shaping.effort, prompt_file)
    File.rm(prompt_file)
    System.halt(status)
  end

  defp fail(reason) do
    IO.puts(:stderr, reason)
    System.halt(1)
  end
end
