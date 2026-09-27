# A small controller stand-in for `test/kogen/process_custody_test.exs`'s
# real-exit-path tests. It exercises the exact production pieces (the real
# `Kogen.ProcessCustody.acquire/1`/`run/3`/`release/1`, and the real signal
# trap `Mix.Tasks.Kogen.Build.SignalHandler` that `mix kogen.build` installs)
# without depending on a full Build.
#
# Usage: mix run test/support/custody_controller_standin.exs <mode> <control> <out>
#   mode is one of: hang | stop | timeout
#   control is the control checkout (holds .kogen/build.lock)
#   out is the fake provider's output directory (pid files)
#
# Prints "READY" once the lock is held, the stand-in's group is recorded,
# and the fake provider has written both pid files, so a driver can
# synchronize before sending a signal.

[mode, control, out] = System.argv()

provider =
  System.get_env("FAKE_PROVIDER") ||
    raise "FAKE_PROVIDER must name the fake orphaning provider script"

launch = fn ->
  Kogen.ProcessCustody.run([provider, out], System.tmp_dir!(),
    control: control,
    role: "developer"
  )
end

case mode do
  "hang" ->
    :os.set_signal(:sighup, :handle)
    :os.set_signal(:sigterm, :handle)
    :gen_event.add_handler(:erl_signal_server, Mix.Tasks.Kogen.Build.SignalHandler, control)

    {:ok, _} = Kogen.ProcessCustody.acquire(control)
    Kogen.ProcessCustody.claim(control, "standin")
    Task.start(launch)

    wait_for_ready = fn wait_for_ready ->
      group_recorded? =
        case Kogen.ProcessCustody.read_lock(control) do
          {:ok, %{"groups" => groups}} when groups != [] -> true
          _ -> false
        end

      pid_files_written? =
        Enum.all?(["provider.pid", "grandchild.pid"], fn name ->
          case File.read(Path.join(out, name)) do
            {:ok, contents} -> String.trim(contents) != ""
            _ -> false
          end
        end)

      if group_recorded? and pid_files_written? do
        :ok
      else
        Process.sleep(10)
        wait_for_ready.(wait_for_ready)
      end
    end

    wait_for_ready.(wait_for_ready)
    IO.puts("READY")
    Process.sleep(:infinity)

  "stop" ->
    {:ok, _} = Kogen.ProcessCustody.acquire(control)
    Kogen.ProcessCustody.claim(control, "standin")
    task = Task.async(launch)

    wait_for_group = fn wait_for_group ->
      case Kogen.ProcessCustody.read_lock(control) do
        {:ok, %{"groups" => groups}} when groups != [] ->
          :ok

        _ ->
          Process.sleep(10)
          wait_for_group.(wait_for_group)
      end
    end

    wait_for_group.(wait_for_group)
    IO.puts("READY")
    # A normal Stop: the controller tears its groups down itself and exits 0.
    Kogen.ProcessCustody.release(control)
    Task.await(task, 5_000)
    IO.puts("STOPPED")

  "timeout" ->
    {:ok, _} = Kogen.ProcessCustody.acquire(control)
    Kogen.ProcessCustody.claim(control, "standin")
    IO.puts("READY")

    {:ok, facts} =
      Kogen.ProcessCustody.run([provider, out], System.tmp_dir!(),
        control: control,
        role: "developer",
        timeout_ms: 300
      )

    Kogen.ProcessCustody.release(control)
    IO.puts("TIMED_OUT=#{facts["timed_out"]}")
end
