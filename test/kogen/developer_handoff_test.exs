defmodule Kogen.DeveloperHandoffTest do
  use ExUnit.Case, async: true

  alias Kogen.Build.DeveloperHandoff

  test "schema binds the current token, IDs, cardinalities, and honest statuses" do
    contract = %{
      scenarios: [%{"id" => "s1"}, %{"id" => "s2"}],
      risks: [%{"id" => "r1"}]
    }

    assert {:ok, bytes} =
             DeveloperHandoff.schema(contract, "current-token", [%{"id" => "F1"}])

    schema = Jason.decode!(bytes)
    assert schema["additionalProperties"] == false
    assert schema["properties"]["attempt_token"]["enum"] == ["current-token"]

    scenarios = schema["properties"]["scenarios"]
    assert {scenarios["minItems"], scenarios["maxItems"]} == {2, 2}
    assert scenarios["items"]["properties"]["id"]["enum"] == ["s1", "s2"]
    assert scenarios["items"]["properties"]["status"]["enum"] == ["ready", "incomplete"]
    assert scenarios["items"]["properties"]["implementation"]["minItems"] == 1

    assert schema["properties"]["findings"]["items"]["properties"]["status"]["enum"] ==
             ["addressed", "blocked", "disputed"]
  end

  test "empty optional collections have no invalid empty enum" do
    contract = %{scenarios: [%{"id" => "only"}], risks: []}
    assert {:ok, bytes} = DeveloperHandoff.schema(contract, "token", [])
    schema = Jason.decode!(bytes)

    for name <- ~w(risks findings) do
      collection = schema["properties"][name]
      assert collection["minItems"] == 0
      assert collection["maxItems"] == 0
      refute Map.has_key?(collection["items"]["properties"]["id"], "enum")
    end
  end
end
