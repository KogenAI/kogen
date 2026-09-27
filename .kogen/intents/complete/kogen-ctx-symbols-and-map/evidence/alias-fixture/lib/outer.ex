defmodule Outer do
  def f(x \\ Kit.Box.new()), do: x
  def g do
    alias Kit.Box
    Box.open()
  end
  defmodule Inner do
    alias Other.Thing, as: Box
    def h, do: Box.open()
  end
  def k, do: Box.close()
end
