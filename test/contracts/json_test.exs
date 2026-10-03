defmodule Kogen.Contracts.JSONTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.JSON

  test "returns an invalid-json error for malformed input" do
    assert {:error, {:invalid_json, _detail}} = JSON.decode("{")
  end

  test "accepts duplicate object keys with the last value winning" do
    assert {:ok, %{"key" => "last", "nested" => %{"value" => 2}}} =
             JSON.decode(~s({"key":"first","nested":{"value":1,"value":2},"key":"last"}))
  end

  test "rejects trailing garbage after a valid value" do
    assert {:error, {:invalid_json, {:trailing_data, 8}}} = JSON.decode("{} garbage")
  end
end
