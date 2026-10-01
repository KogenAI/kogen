defmodule Kogen.BareLoop do
  @moduledoc false

  import Bitwise

  @endpoint ~c"https://chatgpt.com/backend-api/codex/responses"
  @model "gpt-6-luna"
  @instructions "Return only the requested output."
  @login_help "Use the installed Codex login (`codex login` or `codex login --device-auth`), then rerun."
  @timeout 300_000

  def cli([prompt, output_path]) do
    case run(prompt, output_path) do
      {:ok, _path} -> :ok
      {:error, message} -> {:error, message}
    end
  end

  def cli(_args), do: {:error, "Usage: elixir loop.exs '<prompt>' /existing/parent/newfile"}

  def run(prompt, output_path, options \\ []) when is_binary(prompt) and is_binary(output_path) do
    auth_loader = Keyword.get(options, :auth_loader, &load_auth/0)
    transport = Keyword.get(options, :transport, &subscription_request/2)

    with {:ok, path} <- preflight(output_path),
         {:ok, credentials} <- auth_loader.(),
         {:ok, output} <- transport.(request(prompt), credentials),
         :ok <- safe_output(output, credentials),
         :ok <- write_new(path, output) do
      {:ok, path}
    end
  rescue
    _ -> {:error, "The request could not be completed."}
  end

  def request(prompt) when is_binary(prompt) do
    %{
      "model" => @model,
      "instructions" => @instructions,
      "input" => [
        %{
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => prompt}]
        }
      ],
      "reasoning" => %{"effort" => "max"}
    }
  end

  def parse_stream(body) when is_binary(body) do
    state =
      body
      |> String.replace("\r\n", "\n")
      |> String.split("\n\n")
      |> Enum.reduce(%{response: nil, items: [], failed: false}, &read_frame/2)

    cond do
      state.failed ->
        {:error, "ChatGPT subscription request failed."}

      is_nil(state.response) ->
        {:error, "ChatGPT response ended before completion."}

      state.response["status"] != "completed" ->
        {:error, "ChatGPT response was incomplete."}

      true ->
        output_items =
          case state.response["output"] do
            items when is_list(items) and items != [] -> items
            _ -> state.items
          end

        text = assistant_text(output_items)

        if text == "" do
          {:error, "ChatGPT completed without assistant output."}
        else
          {:ok, text}
        end
    end
  rescue
    _ -> {:error, "ChatGPT returned an unreadable response."}
  end

  defp read_frame(frame, state) do
    data =
      frame
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map(&(&1 |> String.replace_prefix("data:", "") |> String.trim_leading()))
      |> Enum.join("\n")

    case :json.decode(data) do
      %{"type" => "response.output_item.done", "item" => item} when is_map(item) ->
        %{state | items: state.items ++ [item]}

      %{"type" => "response.completed", "response" => response} when is_map(response) ->
        %{state | response: response}

      %{"type" => type} when type in ["response.incomplete", "response.failed", "error"] ->
        %{state | failed: true}

      %{"error" => _error} ->
        %{state | failed: true}

      _ ->
        state
    end
  rescue
    _ -> state
  end

  defp assistant_text(items) when is_list(items) do
    parts =
      for %{"type" => "message", "role" => "assistant", "content" => content} <- items,
          is_list(content),
          %{"type" => "output_text", "text" => text} <- content,
          is_binary(text),
          do: text

    IO.iodata_to_binary(parts)
  end

  defp load_auth do
    path = Path.join(System.user_home!(), ".codex/auth.json")

    with {:ok, %File.Stat{mode: mode}} <- File.stat(path),
         true <- band(mode, 0o077) == 0,
         {:ok, contents} <- File.read(path),
         %{"tokens" => tokens} <- :json.decode(contents),
         %{"access_token" => token, "account_id" => account_id} <- tokens,
         true <- is_binary(token) and token != "" and is_binary(account_id) and account_id != "",
         :ok <- unexpired(token) do
      secrets =
        tokens
        |> Enum.filter(fn {key, value} ->
          String.ends_with?(key, "token") and is_binary(value) and value != ""
        end)
        |> Enum.map(&elem(&1, 1))

      {:ok,
       %{access_token: token, account_id: account_id, secrets: Enum.uniq(secrets)}}
    else
      _ -> {:error, "Codex ChatGPT login is missing, expired, or not private. #{@login_help}"}
    end
  rescue
    _ -> {:error, "Codex ChatGPT login is unavailable. #{@login_help}"}
  end

  defp unexpired(token) do
    with [_header, payload, _signature] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         %{"exp" => expiry} <- :json.decode(json),
         true <- is_integer(expiry) do
      if expiry > System.system_time(:second) + 60, do: :ok, else: {:error, :expired}
    else
      _ -> :ok
    end
  end

  defp preflight(path) when path != "" do
    expanded = Path.expand(path)

    with {:ok, %File.Stat{type: :directory}} <- File.stat(Path.dirname(expanded)) do
      case File.lstat(expanded) do
        {:error, :enoent} -> {:ok, expanded}
        {:ok, _entry} -> {:error, "Output path already exists: #{expanded}"}
        {:error, _reason} -> {:error, "Cannot inspect output path: #{expanded}"}
      end
    else
      {:ok, _other} -> {:error, "Output parent is not a directory."}
      {:error, _reason} -> {:error, "Output parent directory does not exist."}
    end
  rescue
    _ -> {:error, "Invalid output path."}
  end

  defp preflight(_path), do: {:error, "Output path must name a new file."}

  defp safe_output(output, credentials) when is_binary(output) do
    sensitive =
      [Map.get(credentials, :access_token), Map.get(credentials, :account_id)] ++
        Map.get(credentials, :secrets, [])

    if Enum.any?(sensitive, fn value ->
         is_binary(value) and value != "" and String.contains?(output, value)
       end) do
      {:error, "Refusing to save a response containing cached login material."}
    else
      :ok
    end
  end

  defp safe_output(_output, _credentials),
    do: {:error, "ChatGPT completed without assistant output."}

  defp subscription_request(request, credentials) do
    with {:ok, _apps} <- Application.ensure_all_started(:inets),
         {:ok, _apps} <- Application.ensure_all_started(:ssl) do
      session_id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

      headers = [
        {~c"authorization", String.to_charlist("Bearer #{credentials.access_token}")},
        {~c"chatgpt-account-id", String.to_charlist(credentials.account_id)},
        {~c"openai-beta", ~c"responses=experimental"},
        {~c"originator", ~c"kogen"},
        {~c"accept", ~c"text/event-stream"},
        {~c"session_id", String.to_charlist(session_id)},
        {~c"user-agent", ~c"kogen-bare-loop"}
      ]

      body =
        request
        |> Map.put("stream", true)
        |> Map.put("store", false)
        |> Map.put("prompt_cache_key", session_id)
        |> :json.encode()
        |> IO.iodata_to_binary()

      case :httpc.request(
             :post,
             {@endpoint, headers, ~c"application/json", body},
             [
               {:timeout, @timeout},
               {:connect_timeout, 30_000},
               {:autoredirect, false},
               {:autoretry, 0},
               {:ssl, [{:verify, :verify_peer}, {:cacerts, :public_key.cacerts_get()}]}
             ],
             [{:body_format, :binary}]
           ) do
        {:ok, {{_version, status, _reason}, _headers, response_body}} when status in 200..299 ->
          parse_stream(response_body)

        {:ok, {{_version, status, _reason}, _headers, _body}} when status in [401, 403] ->
          {:error, "ChatGPT rejected the installed Codex login. #{@login_help}"}

        {:ok, {{_version, 429, _reason}, _headers, _body}} ->
          {:error, "ChatGPT subscription request was rate or quota limited."}

        {:ok, {{_version, _status, _reason}, _headers, _body}} ->
          {:error, "ChatGPT subscription request failed."}

        {:error, _reason} ->
          {:error, "ChatGPT subscription request could not connect."}
      end
    else
      _ -> {:error, "ChatGPT subscription transport could not start."}
    end
  rescue
    _ -> {:error, "ChatGPT subscription request failed."}
  end

  defp write_new(path, output) when is_binary(output) and output != "" do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, device} ->
        write_open_file(path, device, output)

      {:error, :eexist} ->
        {:error, "Output path appeared during the request and was preserved: #{path}"}

      {:error, _reason} ->
        {:error, "Could not create output file: #{path}"}
    end
  end

  defp write_new(_path, _output), do: {:error, "ChatGPT completed without assistant output."}

  defp write_open_file(path, device, output) do
    case IO.binwrite(device, output) do
      :ok ->
        case File.close(device) do
          :ok -> :ok
          _ -> remove_partial(path)
        end

      _ ->
        File.close(device)
        remove_partial(path)
    end
  rescue
    _ ->
      File.close(device)
      remove_partial(path)
  end

  defp remove_partial(path) do
    File.rm(path)
    {:error, "Could not finish writing the output file."}
  end
end
