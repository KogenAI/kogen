defmodule HelloApp.GreeterTest do
  use ExUnit.Case, async: true

  alias HelloApp.Greeter

  test "greets a named person" do
    assert Greeter.hello("Almir") == "Hello, Almir!"
  end

  test "greets an empty name" do
    assert Greeter.hello("") == "Hello, !"
  end
end
