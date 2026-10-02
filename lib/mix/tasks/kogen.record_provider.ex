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
         request =
           Codec.recording_request(
             Keyword.get(options, :scenario, "text"),
             Keyword.get(options, :model, "gpt-6-luna"),
             Keyword.get(options, :effort, "low")
           ),
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
    with {:ok, contents} <- Codec.encode_recording(request, events) do
      if safe_fixture?(contents, config) do
        {:ok, contents}
      else
        {:error, :secret_in_fixture}
      end
    end
  end

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
      {:error, _reason} -> {:error, :fixture_write_failed}
      false -> {:error, :fixture_write_failed}
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
