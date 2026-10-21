defmodule Kogen.WorkingContextTest do
  use ExUnit.Case, async: true
  alias Kogen.{ChatGPT, WorkingContext}

  test "complete rendered request has exact UTF-8 size and adjacent inclusive boundaries" do
    literal = "  Δ🙂\r\n/path with spaces/診断.txt\n  "

    body =
      ChatGPT.request_body(
        %{model: "gpt-6.1-sol", effort: "medium"},
        "policy",
        [%{"role" => "user", "content" => literal}],
        [%{"type" => "function", "name" => "sample"}]
      )

    assert JSON.encode!(body) |> JSON.decode!() == body
    assert WorkingContext.measure(body).rendered_bytes == byte_size(JSON.encode!(body))
    assert JSON.encode!(body) =~ "policy"
    assert JSON.encode!(body) =~ "sample"
    empty = Map.put(body, "padding", "")
    size = byte_size(JSON.encode!(empty))

    for {bytes, fits} <- [{524_287, true}, {524_288, true}, {524_289, false}] do
      request = Map.put(empty, "padding", String.duplicate("x", bytes - size))

      assert WorkingContext.measure(request) == %{
               rendered_bytes: bytes,
               input_budget_bytes: 524_288,
               output_reserve_tokens: 131_072,
               fits: fits
             }
    end

    assert Enum.at(body["input"], 1)["content"] |> hd() |> Map.fetch!("text") == literal
  end
end
