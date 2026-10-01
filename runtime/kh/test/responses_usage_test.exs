defmodule Kh.ResponsesUsageTest do
  use ExUnit.Case, async: false

  test "incomplete Responses usage remains partial in session evidence" do
    root = temp_dir!()
    complete = %{
      "input_tokens" => 17,
      "input_tokens_details" => %{"cached_tokens" => 4},
      "output_tokens" => 6,
      "output_tokens_details" => %{"reasoning_tokens" => 2}
    }

    for {label, usage, expected_state} <- [
          {"empty", %{}, "partial"},
          {"input-only", %{"input_tokens" => 17}, "partial"},
          {"complete", complete, "reported"}
        ] do
      checkpoint = Path.join(root, label <> ".json")
      response = %{
        "type" => "response.completed",
        "response" => %{
          "id" => "offline-response",
          "status" => "completed",
          "output" => [
            %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "done"}]}
          ],
          "usage" => usage
        }
      }

      with_http_stream(["data: " <> JSON.encode!(response) <> "\n\n"], fn ->
        {:ok, session} = Kh.Session.open(%{
          provider: :chatgpt,
          model: "gpt-6.1-sol",
          cwd: root,
          system_prompt: "test system",
          checkpoint_path: checkpoint,
          access_token: "offline-opaque-token",
          account_id: "offline-account",
          timeout_s: 5
        })

        try do
          {:ok, run_ref} = Kh.Session.run(session, "check usage")
          {:ok, result} = Kh.Session.await(session, run_ref, 5_000)
          evidence = result["evidence"]

          assert get_in(result, ["summary", "status"]) == "ok"
          assert evidence["usage_state"] == expected_state

          if expected_state == "reported" do
            assert evidence["usage"] == %{
                     "input" => 13,
                     "cached_input" => 4,
                     "cache_write" => 0,
                     "output" => 6,
                     "reasoning" => 2
                   }
          else
            assert evidence["usage"] == nil
            assert get_in(result, ["summary", "usage"]) == nil
            assert evidence["turns_without_usage"] == 1
          end
        after
          GenServer.stop(session)
        end
      end)
    end
  end

  defp with_http_stream(chunks, fun) do
    Code.ensure_loaded!(Kh.Http)
    {Kh.Http, original_beam, original_path} = :code.get_object_code(Kh.Http)
    previous_options = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    try do
      Code.compile_string("""
      defmodule Kh.Http do
        def post_stream(_url, _headers, _body, on_data, _deadline) do
          Enum.each(:persistent_term.get({__MODULE__, :test_chunks}, []), on_data)
          :ok
        end
      end
      """)

      :persistent_term.put({Kh.Http, :test_chunks}, chunks)
      fun.()
    after
      :persistent_term.erase({Kh.Http, :test_chunks})
      :code.purge(Kh.Http)
      {:module, Kh.Http} = :code.load_binary(Kh.Http, original_path, original_beam)
      Code.compiler_options(previous_options)
    end
  end

  defp temp_dir! do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    path = Path.join(System.tmp_dir!(), "kh-usage-test-#{suffix}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
