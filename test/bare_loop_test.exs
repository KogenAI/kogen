defmodule Kogen.BareLoopTest do
  use ExUnit.Case, async: true

  alias Kogen.BareLoop

  test "sends the literal prompt in the fixed request and writes exact response text" do
    prompt = "  Keep every space.\nAnd this newline.  "
    response = "first line\nsecond line"
    credentials = %{access_token: "test-token", account_id: "test-account"}
    path = new_path("result.txt")

    transport = fn request, received_credentials ->
      send(self(), {:request, request, received_credentials})
      {:ok, response}
    end

    assert {:ok, ^path} =
             BareLoop.run(prompt, path,
               auth_loader: fn -> {:ok, credentials} end,
               transport: transport
             )

    assert_receive {:request, request, ^credentials}
    assert request == %{
             "model" => "gpt-6-luna",
             "instructions" => "Return only the requested output.",
             "input" => [
               %{
                 "role" => "user",
                 "content" => [%{"type" => "input_text", "text" => prompt}]
               }
             ],
             "reasoning" => %{"effort" => "max"}
           }

    assert File.read!(path) == response
  end

  test "missing parent, files, and symlinks fail before authentication or a request" do
    calls = fn -> flunk("preflight must stop before authentication or transport") end
    missing = new_path("missing/response.txt")
    existing = new_path("existing.txt")
    symlink = new_path("existing-link.txt")
    File.write!(existing, "keep me")
    File.ln_s!(existing, symlink)

    assert {:error, "Output parent directory does not exist."} =
             BareLoop.run("prompt", missing, auth_loader: calls, transport: calls)

    assert {:error, "Output path already exists: " <> _path} =
             BareLoop.run("prompt", existing, auth_loader: calls, transport: calls)

    assert {:error, "Output path already exists: " <> _path} =
             BareLoop.run("prompt", symlink, auth_loader: calls, transport: calls)
    assert File.read!(existing) == "keep me"
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(symlink)
  end

  test "request failure leaves no output file" do
    path = new_path("failed.txt")

    assert {:error, _} =
             BareLoop.run("prompt", path,
               auth_loader: fn -> {:ok, %{access_token: "token", account_id: "account"}} end,
               transport: fn _request, _credentials -> {:error, "offline failure"} end
             )

    refute File.exists?(path)
  end

  test "response text containing cached login material is not saved" do
    path = new_path("credential.txt")
    credentials = %{access_token: "cached-access-token", account_id: "private-account"}

    assert {:error, _} =
             BareLoop.run("prompt", path,
               auth_loader: fn -> {:ok, credentials} end,
               transport: fn _request, _credentials -> {:ok, "text cached-access-token"} end
             )

    refute File.exists?(path)
  end

  test "a completed response uses output items when its output list is empty" do
    item = assistant_item("fallback text")

    stream =
      frame(%{"type" => "response.output_item.done", "item" => item}) <>
        frame(%{
          "type" => "response.completed",
          "response" => %{"status" => "completed", "output" => []}
        })

    assert {:ok, "fallback text"} = BareLoop.parse_stream(stream)
  end

  test "a nonempty completed output is preferred and incomplete output is rejected" do
    fallback = assistant_item("done item")
    preferred = assistant_item("response output")

    completed =
      frame(%{"type" => "response.output_item.done", "item" => fallback}) <>
        frame(%{
          "type" => "response.completed",
          "response" => %{"status" => "completed", "output" => [preferred]}
        })

    incomplete =
      frame(%{
        "type" => "response.incomplete",
        "response" => %{"status" => "incomplete", "output" => [preferred]}
      })

    assert {:ok, "response output"} = BareLoop.parse_stream(completed)
    assert {:error, _} = BareLoop.parse_stream(incomplete)
  end

  defp assistant_item(text) do
    %{
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => text}]
    }
  end

  defp frame(event), do: "data: " <> IO.iodata_to_binary(:json.encode(event)) <> "\n\n"

  defp new_path(name) do
    directory = Path.join(System.tmp_dir!(), "kogen-bare-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(directory) end)
    Path.join(directory, name)
  end
end
