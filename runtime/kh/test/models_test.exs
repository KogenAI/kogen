defmodule Kh.ModelsRuntimeTest do
  use ExUnit.Case, async: true

  test "documented ChatGPT models render max as requested without clamping" do
    for model_id <- ~w(gpt-6-luna gpt-6-astra gpt-6.1-sol) do
      model = Kh.Models.chatgpt(model_id)
      assert Kh.Models.effort(model, "max") == {"max", "as requested"}

      body = Kh.Provider.Responses.build_body(model, "system", [%{role: :user, text: "hello"}], [], %{session_id: "session", effort_sent: "max"})
      assert body["reasoning"]["effort"] == "max"
    end

    assert Kh.Models.effort(Kh.Models.chatgpt("gpt-5.5"), "max") == {nil, "max unsupported; omitted"}
  end
end
