defmodule Kogen.Main do
  @moduledoc "Entry point of the core: `bin/kogen eval 'Kogen.Main.main()'`, started by `kogen` (CLI-9)."
  alias Kogen.{Bridge, Error}
  require Logger

  def main do
    {:ok, _} = Application.ensure_all_started(:kogen)

    # Logs at info unless the caller asks the BEAM for another level (ERL_AFLAGS="-kernel logger_level debug").
    Logger.configure(level: Application.get_env(:kernel, :logger_level, :info))
    # The protocol is UTF-8 JSON bytes whatever the caller's locale: no character translation.
    :ok = :io.setopts(:standard_io, encoding: :latin1)
    :ok = :io.setopts(:standard_error, encoding: :latin1)
    Bridge.start_reader()
    %{"type" => "hello"} = Bridge.recv()
    Bridge.send_msg(%{"type" => "hello"})
    %{"type" => "run"} = req = Bridge.recv()
    Logger.debug("kogen core: #{req["command"]} in #{req["cwd"]}")

    :persistent_term.put(:kogen_caller, %{
      env: req["env"],
      cwd: req["cwd"],
      install_root: req["install_root"]
    })

    code = run(req)
    Bridge.send_msg(%{"type" => "exit", "code" => code})
    # kogen closes stdin once it has read the exit message.
    receive do
      :eof -> System.halt(0)
    end
  end

  defp run(req) do
    try do
      if Map.has_key?(req, "context") do
        if req["command"] != "build", do: Kogen.BuildContext.unavailable!()
        Kogen.BuildContext.validate!(req["context"])
      end

      dispatch(req)
    rescue
      e in Error ->
        Bridge.out(Error.render(e))

        if req["command"] in ["build", "resume"] and Process.get(:local_record) == nil,
          do:
            Bridge.puts(
              "  no newly created Build run; correct the named prerequisite before trying again"
            )

        e.exit

      e ->
        # A Kogen bug (CLI-6): one line on stdout, the details in the log on stderr.
        Logger.error(Exception.format(:error, e, __STACKTRACE__))

        Bridge.puts(
          "controller/internal_error: " <>
            (e |> Exception.message() |> String.split("\n") |> hd())
        )

        70
    catch
      {:cancel, sig} -> signal_exit(sig)
    end
  end

  def signal_exit("SIGINT"), do: 130
  def signal_exit("SIGTERM"), do: 143
  def signal_exit("SIGHUP"), do: 129

  defp dispatch(%{"command" => "preflight"} = r), do: Kogen.Preflight.run(r)

  defp dispatch(%{"command" => "version"}) do
    Bridge.puts(Kogen.version())
    0
  end

  defp dispatch(%{"command" => "init"} = r), do: Kogen.Init.run(r["project"])
  defp dispatch(%{"command" => "list"}), do: Kogen.ChatGPT.status()
  defp dispatch(%{"command" => "login"}), do: Kogen.ChatGPT.login()

  defp dispatch(%{"command" => "shape"} = r),
    do: Kogen.Shape.run(r["project"], r["slug"], r["input"], r["input_path"])

  defp dispatch(%{"command" => "refine"} = r),
    do: Kogen.Refine.run(r["project"], r["slug"], r["hash"], r["input"], r["input_path"])

  defp dispatch(%{"command" => "approve"} = r),
    do: Kogen.Approve.run(r["project"], r["slug"], r["hash"], r["by"])

  defp dispatch(%{"command" => "resume"} = r), do: Kogen.Build.resume(r["project"], r["slug"])

  defp dispatch(%{"command" => "build"} = r),
    do: Kogen.Build.run(r["project"], r["slug"], r["context"])
end
