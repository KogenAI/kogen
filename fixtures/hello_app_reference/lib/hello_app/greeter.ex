defmodule HelloApp.Greeter do
  @moduledoc "Builds greetings in English and Bosnian."

  @spec hello(String.t()) :: String.t()
  def hello(name), do: "Hello, #{name}!"

  @spec greet(String.t(), atom()) :: String.t() | {:error, :unsupported_language}
  def greet(name, :en), do: hello(name)
  def greet(name, :bs), do: "Zdravo, #{name}!"
  def greet(_name, _language), do: {:error, :unsupported_language}
end
