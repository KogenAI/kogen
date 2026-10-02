defmodule Mix.Tasks.Kogen.RecordProvider do
  @shortdoc "Records one redacted ChatGPT Responses stream"
  @moduledoc "Makes one live provider request and writes its SSE events as a JSONL fixture."
  use Mix.Task
  use Boundary, classify_to: Kogen.Mix

  alias Kogen.Contracts.ModelRequest
  alias Kogen.Provider.ChatGPT
  alias Kogen.Provider.ChatGPT.Codec

  @spec run([String.t()]) :: :ok
  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    with {:ok, options} <- parse_options(args),
         {:ok, auth_path} <- required_auth_path(options),
         {:ok, config} <- ChatGPT.config(auth_path),
         request = request(Keyword.get(options, :scenario, "text"), options),
         {:ok, response, body} <- ChatGPT.respond_with_transcript(config, request),
         :ok <- expected_response(request, response),
         {:ok, events} <- Codec.sse_lines(body),
         {:ok, fixture_path} <- fixture_path(options, request),
         {:ok, contents} <- fixture_contents(config, request, events),
         :ok <- write_fixture(fixture_path, contents) do
      Mix.shell().info("Recorded #{request.model} SSE fixture: #{fixture_path}")
    else
      {:error, %Kogen.Contracts.ProviderError{class: class}} ->
        Mix.raise("Provider recording failed (#{class}).")

      {:error, reason} when is_atom(reason) ->
        Mix.raise("Provider recording failed (#{reason}).")
    end
  end

  defp parse_options(args) do
    {options, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          auth_path: :string,
          model: :string,
          effort: :string,
          scenario: :string,
          output: :string
        ]
      )

    scenario = Keyword.get(options, :scenario, "text")
    model = Keyword.get(options, :model, "gpt-6-luna")
    effort = Keyword.get(options, :effort, "low")

    if rest == [] and invalid == [] and scenario in ["text", "tool_call"] and
         is_binary(model) and model != "" and is_binary(effort) and effort != "" do
      {:ok, options}
    else
      {:error, :invalid_options}
    end
  end

  defp required_auth_path(options) do
    case Keyword.get(options, :auth_path) do
      path when is_binary(path) and path != "" -> {:ok, path}
      _ -> {:error, :missing_auth_path}
    end
  end

  defp request(scenario, options) do
    %ModelRequest{
      model: Keyword.get(options, :model, "gpt-6-luna"),
      effort: Keyword.get(options, :effort, "low"),
      instructions: instructions(scenario),
      input: [user_input(scenario)],
      tools: tools(scenario),
      previous_response_id: nil
    }
  end

  defp instructions("tool_call"),
    do: "Call the echo_phrase function exactly once with phrase set to recorded."

  defp instructions(_scenario), do: "Answer exactly with the word recorded."

  defp user_input("tool_call"),
    do: %{
      "role" => "user",
      "content" => [%{"type" => "input_text", "text" => "Use the function tool now."}]
    }

  defp user_input(_scenario),
    do: %{"role" => "user", "content" => [%{"type" => "input_text", "text" => "Reply now."}]}

  defp tools("tool_call") do
    [
      %{
        "type" => "function",
        "name" => "echo_phrase",
        "description" => "Echo a phrase supplied by the user.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{"phrase" => %{"type" => "string"}},
          "required" => ["phrase"],
          "additionalProperties" => false
        },
        "strict" => false
      }
    ]
  end

  defp tools(_scenario), do: []

  defp expected_response(%ModelRequest{tools: []}, %{text: text}) when text != "", do: :ok
  defp expected_response(%ModelRequest{tools: [_]}, %{tool_calls: [_ | _]}), do: :ok
  defp expected_response(_request, _response), do: {:error, :unexpected_response}

  defp fixture_path(options, request) do
    root = Path.dirname(Mix.Project.project_file())
    directory = Path.join(root, "test/provider/fixtures")
    scenario = Keyword.get(options, :scenario, "text")
    model_name = String.replace(request.model, ~r/[^a-zA-Z0-9.-]/, "-")
    default = Path.join(directory, "#{model_name}-#{scenario}.jsonl")
    output = Path.expand(Keyword.get(options, :output, default), root)

    if Path.dirname(output) == Path.expand(directory) and Path.extname(output) == ".jsonl" do
      {:ok, output}
    else
      {:error, :invalid_output_path}
    end
  end

  defp fixture_contents(config, request, events) do
    with {:ok, fingerprint} <- Codec.request_fingerprint(request) do
      rows = [%{"kind" => "recording", "model" => request.model, "request_sha256" => fingerprint}]
      rows = rows ++ Enum.map(events, &%{"kind" => "sse", "data" => &1})
      contents = Enum.map_join(rows, "\n", &encode_row/1) <> "\n"

      if safe_fixture?(contents, config) do
        {:ok, contents}
      else
        {:error, :secret_in_fixture}
      end
    end
  end

  defp encode_row(row), do: row |> :json.encode() |> IO.iodata_to_binary()

  defp safe_fixture?(contents, config) do
    normalized = String.downcase(contents)

    not String.contains?(normalized, "authorization") and
      not String.contains?(contents, config.access_token) and
      not String.contains?(contents, config.account_id)
  end

  defp write_fixture(path, contents) do
    with :ok <- ensure_fixture_directory(Path.dirname(path)),
         :ok <- safe_destination(path),
         :ok <- File.write(path, contents),
         {:ok, saved} <- File.read(path),
         true <- saved == contents do
      :ok
    else
      _ -> {:error, :fixture_write_failed}
    end
  end

  defp ensure_fixture_directory(directory) do
    case File.lstat(directory) do
      {:ok, %{type: :directory}} -> :ok
      {:ok, _other} -> {:error, :invalid_output_path}
      {:error, :enoent} -> File.mkdir_p(directory)
      {:error, _reason} -> {:error, :fixture_write_failed}
    end
  end

  defp safe_destination(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %{type: :regular}} -> :ok
      _ -> {:error, :invalid_output_path}
    end
  end
end
