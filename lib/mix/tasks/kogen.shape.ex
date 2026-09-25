defmodule Mix.Tasks.Kogen.Shape do
  use Mix.Task

  use Boundary,
    deps: [Kogen.Intent, Kogen.Harness, Kogen.Git, Kogen.ExecutionPolicy, Mix]

  @shortdoc "Starts fresh shaping or continues an existing draft in a new conversation"
  @moduledoc """
  `mix kogen.shape [--route <name>]` mints a new Intent.
  `mix kogen.shape [--route <name>] <draft-slug>` opens an existing draft in a
  fresh interactive conversation. The session runs on the named route from
  `.kogen/config.yaml`, or on its `default_route` without `--route`; a
  continuation uses this session's route, whatever route shaped the draft.
  Launch never rewrites the selected draft or restores a previous session.
  Both modes render the maintained Shaping producer contract, including the
  required per-scenario proof map consumed by future Build readiness planning.
  """

  @prompt_path "priv/kogen/prompts/shaping.md"
  @usage "usage: mix kogen.shape [--route <name>] [draft-slug]"

  @impl Mix.Task
  def run(args) do
    with {:ok, route, slugs} <- parse(args),
         {:ok, config} <- Kogen.Intent.read_config(".kogen/config.yaml", route),
         {:ok, selection} <- select(slugs) do
      shape(config, selection)
    else
      {:error, reason} -> fail(reason)
    end
  end

  defp parse(args) do
    case OptionParser.parse(args, strict: [route: :string]) do
      {[], slugs, []} when length(slugs) <= 1 -> {:ok, nil, slugs}
      {[route: route], slugs, []} when length(slugs) <= 1 and route != "" -> {:ok, route, slugs}
      _usage -> {:error, @usage}
    end
  end

  defp select([]), do: {:ok, nil}
  defp select([slug]), do: Kogen.Intent.read_draft(slug)

  defp shape(config, selection) do
    with {:ok, branch} <- Kogen.Git.current_branch(),
         {:ok, head} <- Kogen.Git.head_sha(),
         {:ok, runtime} <- Kogen.Harness.open_roles(config, [:shaping, :expert]) do
      try do
        launch(config, selection, branch, head, runtime)
      after
        Kogen.Harness.close(runtime)
      end
    else
      {:error, reason} -> fail(reason)
    end
  end

  defp launch(config, selection, branch, head, runtime) do
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
      "route" => config.route,
      "harness" => Kogen.Intent.role_harness(config, :shaping),
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

    status =
      Kogen.Harness.exec_shaper(
        config.shaping.model,
        config.shaping.effort,
        prompt_file,
        Kogen.Harness.role_context(runtime, :shaping)
      )

    File.rm(prompt_file)
    System.halt(status)
  end

  defp fail(reason) do
    IO.puts(:stderr, reason)
    System.halt(1)
  end
end
