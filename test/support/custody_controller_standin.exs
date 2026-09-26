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
# Prints "READY" once the lock is held and the fake provider's launch has
# started, so a driver can synchronize before sending a signal.

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
    # Give the supervisor time to spawn and register before announcing ready.
    Process.sleep(300)
    IO.puts("READY")
    Process.sleep(:infinity)

  "stop" ->
    {:ok, _} = Kogen.ProcessCustody.acquire(control)
    Kogen.ProcessCustody.claim(control, "standin")
    task = Task.async(launch)
    Process.sleep(300)
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
