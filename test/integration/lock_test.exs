defmodule Kogen.Integration.LockTest do
  use ExUnit.Case, async: false

  for format <- [:pid_file, :directory] do
    test "AUT-4/GPT-6 concurrent stale recovery preserves the live owner (#{format})" do
      root =
        Path.join(
          System.tmp_dir!(),
          "kogen-lock-#{System.pid()}-#{System.unique_integer([:positive])}"
        )

      File.mkdir!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      lock = Path.join(root, "build.lock")

      case unquote(format) do
        :pid_file ->
          File.write!(lock, "2147483647\n")

        :directory ->
          File.mkdir!(lock)
          File.write!(Path.join(lock, "dead-owner"), "2147483647\n")
      end

      bin = Path.join(root, "bin")
      File.mkdir!(bin)
      wrapper = Path.join(bin, "kill")

      File.write!(wrapper, """
      #!/bin/sh
      if [ "$1" = -0 ] && [ "$2" = 2147483647 ]; then
        touch "$LOCK_CASE/at-check-$CONTENDER"
        while [ ! -f "$LOCK_CASE/go-$CONTENDER" ]; do sleep 0.02; done
      fi
      exec /bin/kill "$@"
      """)

      File.chmod!(wrapper, 0o755)

      script = Path.join(root, "contender.exs")

      File.write!(script, """
      Code.require_file(System.fetch_env!("LOCK_SOURCE"))
      root = System.fetch_env!("LOCK_CASE")
      label = System.fetch_env!("CONTENDER")
      lock = Path.join(root, "build.lock")
      result = Kogen.Lock.acquire(lock)
      # Even a caller without ownership must not release someone else's lock.
      if label == "B", do: Kogen.Lock.release(lock)
      File.write!(Path.join(root, "result-" <> label), JSON.encode!(%{pid: System.pid(), result: inspect(result)}))
      wait = fn wait ->
        if not File.exists?(Path.join(root, "stop-" <> label)) do
          Process.sleep(20)
          wait.(wait)
        end
      end
      wait.(wait)
      Kogen.Lock.release(lock)
      """)

      ports =
        for label <- ["A", "B"] do
          env = %{
            "PATH" => bin <> ":" <> System.fetch_env!("PATH"),
            "LOCK_CASE" => root,
            "LOCK_SOURCE" => Path.expand("../../lib/kogen/lock.ex", __DIR__),
            "CONTENDER" => label,
            "ERL_FLAGS" => "+S 2:2"
          }

          port =
            Port.open({:spawn_executable, String.to_charlist(System.find_executable("elixir"))}, [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              {:args, [String.to_charlist(script)]},
              {:env,
               Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)}
            ])

          on_exit(fn ->
            case Port.info(port, :os_pid) do
              {:os_pid, pid} ->
                System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

              nil ->
                :ok
            end
          end)

          port
        end

      for label <- ["A", "B"], do: wait_file!(Path.join(root, "at-check-" <> label))
      File.touch!(Path.join(root, "go-A"))
      a = result!(root, "A")
      assert a["result"] == ~s({:removed_stale, "2147483647"})
      assert owner(lock) == a["pid"]
      File.touch!(Path.join(root, "go-B"))
      b = result!(root, "B")
      assert b["result"] == ~s({:held, "#{a["pid"]}"})
      assert owner(lock) == a["pid"]
      File.touch!(Path.join(root, "stop-B"))
      File.touch!(Path.join(root, "stop-A"))
      for port <- ports, do: assert_receive({^port, {:exit_status, 0}}, 10_000)
      refute File.exists?(lock)
    end
  end

  test "release cannot remove a later acquisition, including a repeated release" do
    root =
      Path.join(
        System.tmp_dir!(),
        "kogen-lock-release-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    lock = Path.join(root, "build.lock")
    assert Kogen.Lock.acquire(lock) == :ok
    assert Kogen.Lock.release(lock) == :ok
    parent = self()

    holder =
      spawn_link(fn ->
        :ok = Kogen.Lock.acquire(lock)
        send(parent, :acquired)

        receive do
          :release -> Kogen.Lock.release(lock)
        end

        send(parent, :released)
      end)

    assert_receive :acquired
    assert Kogen.Lock.release(lock) == :ok
    assert owner(lock) == System.pid()
    send(holder, :release)
    assert_receive :released
    refute File.exists?(lock)
  end

  defp owner(lock) do
    path = if File.dir?(lock), do: Path.join(lock, hd(File.ls!(lock))), else: lock
    path |> File.read!() |> String.trim()
  end

  defp result!(root, label) do
    path = Path.join(root, "result-" <> label)
    wait_file!(path)
    path |> File.read!() |> JSON.decode!()
  end

  defp wait_file!(path, attempts \\ 500)
  defp wait_file!(path, 0), do: flunk("timed out waiting for #{path}")

  defp wait_file!(path, attempts) do
    unless File.exists?(path) do
      Process.sleep(20)
      wait_file!(path, attempts - 1)
    end
  end
end
