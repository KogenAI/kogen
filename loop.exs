Code.require_file("lib/kogen/bare_loop.ex", __DIR__)

case Kogen.BareLoop.cli(System.argv()) do
  :ok ->
    :ok

  {:error, message} ->
    IO.puts(:stderr, message)
    System.halt(1)
end
