launcher = System.get_env("LAUNCHER")
elixir = System.find_executable("elixir")
port = Port.open({:spawn_executable, System.find_executable("python3")},
  [:nouse_stdio, :exit_status, args: [launcher, elixir, "--erl", "+Bd", "-e", ~s|IO.puts("CHILD READY"); Process.sleep(:infinity)|]])
receive do
  {^port, {:exit_status, s}} -> IO.puts("PARENT saw child exit #{s}"); System.halt(0)
end
