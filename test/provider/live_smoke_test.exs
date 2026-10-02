defmodule Kogen.Provider.ChatGPT.LiveSmokeTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.ModelRequest
  alias Kogen.Contracts.ProviderError
  alias Kogen.Provider.ChatGPT

  @auth_path "/Users/almirsarajcic/.codex/auth.json"

  @tag :live
  test "gpt-6-luna and gpt-6.1-sol answer tiny live requests" do
    if live_selected?() do
      run_smoke()
    else
      IO.puts("Live provider smoke is opt-in; run mix test --only live to execute it.")
      assert true
    end
  end

  defp run_smoke do
    case ChatGPT.config(@auth_path) do
      {:ok, config} ->
        Enum.each(["gpt-6-luna", "gpt-6.1-sol"], fn model ->
          assert {:ok, response} = ChatGPT.respond(config, request(model))
          assert is_binary(response.text) and response.text != ""
        end)

      {:error, %ProviderError{class: :login}} ->
        IO.puts("Live provider smoke skipped: Codex credentials are unavailable or expired.")
        assert true
    end
  end

  defp live_selected? do
    ExUnit.configuration()
    |> Keyword.get(:include, [])
    |> Enum.any?(&(&1 == :live or match?({:live, _value}, &1)))
  end

  defp request(model) do
    %ModelRequest{
      model: model,
      effort: "low",
      instructions: "Reply with the single word ok.",
      input: [%{"role" => "user", "content" => [%{"type" => "input_text", "text" => "ok"}]}],
      tools: [],
      previous_response_id: nil
    }
  end
end
