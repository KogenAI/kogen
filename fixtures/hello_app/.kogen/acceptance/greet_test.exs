defmodule HelloApp.Acceptance.GreetTest do
  use ExUnit.Case, async: true

  alias HelloApp.Greeter

  @tag intent: "greet/A1"
  test "greets in English" do
    assert Greeter.greet("Almir", :en) == "Hello, Almir!"
  end

  @tag intent: "greet/A2"
  test "greets in Bosnian" do
    assert Greeter.greet("Almir", :bs) == "Zdravo, Almir!"
  end

  @tag intent: "greet/A3"
  test "returns an error for an unsupported language" do
    assert Greeter.greet("Almir", :fr) == {:error, :unsupported_language}
  end
end
