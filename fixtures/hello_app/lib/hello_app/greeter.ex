defmodule HelloApp.Greeter do
  @moduledoc "Builds English greetings."

  @spec hello(String.t()) :: String.t()
  def hello(name), do: "Hello, #{name}!"
end
