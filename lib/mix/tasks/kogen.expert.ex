defmodule Mix.Tasks.Kogen.Expert do
  use Mix.Task

  use Boundary, deps: [Kogen.Harness, Kogen.ExecutionPolicy, Mix]

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
  """

  @prompt_path "priv/kogen/prompts/expert.md"

  @impl Mix.Task
  def run(args) do
    with {:ok, config} <- assignment(System.get_env(Kogen.Harness.expert_variable())),
         {:ok, question} <- question(args) do
      consult(config, question)
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
         {:ok, helpers} <- helpers(data) do
      {:ok,
       %{
         route: route,
         caller: caller,
         harness: harness,
         expert: expert,
         helpers: helpers,
         roles: %{expert: harness},
         native_helpers: %{harness => helpers}
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

  defp consult(config, question) do
    case launch(config, question) do
      {:ok, %{message: message}} -> IO.puts(message)
      {:error, reason} -> fail(reason)
    end
  end

  @doc """
  Opens the assigned Expert harness, launches one fresh Expert with the
  rendered Expert prompt and releases the selection. Returns the Expert's
  session and final message, or an error naming the Expert role and harness.
  """
  def launch(config, question, project \\ File.cwd!()) do
    case Kogen.Harness.open(config, project) do
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
