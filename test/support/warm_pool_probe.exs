# Loaded only by the isolated pool scheduling control.
# credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename
defmodule Kogen.WarmPoolProbe do
  use Kogen.IsolatedCase, async: true

  for name <- ~w(slow queued demanded) do
    test name do
      name = unquote(name)
      log = System.fetch_env!("POOL_LOG")
      File.write!(log, "#{name}:start\n", [:append])
      if name == "slow", do: Process.sleep(300)
      File.write!(log, "#{name}:done\n", [:append])
    end
  end
end
