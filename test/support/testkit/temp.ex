defmodule Kogen.Testkit.Temp do
  @moduledoc "Creates unique test directories under the operating system's temporary root."

  @spec create!() :: Path.t()
  def create! do
    root = Path.join(System.tmp_dir!(), "kogen-tests")
    File.mkdir_p!(root)

    path = Path.join(root, "#{System.pid()}-#{System.unique_integer([:positive, :monotonic])}")
    File.mkdir!(path)
    path
  end
end
