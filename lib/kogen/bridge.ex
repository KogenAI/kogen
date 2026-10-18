defmodule Kogen.Bridge do
  @moduledoc """
  The core's side of the protocol with the `kogen` command (CLI-9): one JSON object per line
  on stdin and stdout. stdout carries nothing else; progress goes to stderr.

  `kogen` runs every project command (setup, shell calls, fixers, checks, acceptance, Quint,
  probes) in its own process group, so it can terminate them on interrupt or after a core crash.
  """
  require Logger

  def start_reader do
    main = self()
    spawn_link(fn -> read_loop(main) end)
  end

  defp read_loop(main) do
    case IO.binread(:stdio, :line) do
      line when is_binary(line) ->
        send(main, {:proto, JSON.decode!(line)})
        read_loop(main)

      # kogen is gone (CLI-7): nothing reads stdout any more; cancel like a hangup and stop
      # the command groups kogen can no longer stop, then let main end.
      _eof ->
        :persistent_term.put(:kogen_eof, true)
        send(main, {:proto, %{"type" => "cancel", "signal" => "SIGHUP"}})
        send(main, :eof)
    end
  end

  def send_msg(map) do
    if not :persistent_term.get(:kogen_eof, false),
      do: IO.binwrite(:stdio, [JSON.encode!(map), "\n"])

    :ok
  end

  def recv do
    receive do
      {:proto, msg} -> msg
    end
  end

  @doc "Prints text on the caller's stdout."
  def out(text), do: send_msg(%{"type" => "out", "text" => text})
  def puts(line), do: out(line <> "\n")

  @doc "Progress and notices on stderr (CLI-4)."
  def progress(line), do: IO.binwrite(:stderr, line <> "\n")

  @doc """
  Runs `/bin/sh -c command` in a new process group with stdin closed and the caller's
  environment plus `env`. Returns `%{status, output, timed_out}`. Throws `{:cancel, signal}`
  when the caller interrupts.
  """
  def exec(command, cwd, opts \\ []) do
    id = System.unique_integer([:positive])
    Logger.debug("command #{id} in #{cwd}: #{command}")

    send_msg(%{
      "type" => "exec",
      "id" => id,
      "command" => command,
      "cwd" => cwd,
      "env" => Map.new(Keyword.get(opts, :env, [])),
      "timeout_ms" => Keyword.get(opts, :timeout_ms)
    })

    await(id, Keyword.get(opts, :finish_on_cancel, false), nil)
  end

  # With finish_on_cancel (git commit), an interrupt waits for the command's end, so the caller
  # sees what it left behind (CLI-7).
  defp await(id, finish, cancel) do
    receive do
      {:proto, %{"type" => "exec_started", "id" => ^id, "pgid" => pgid}} ->
        Process.put(:kogen_groups, [pgid | Process.get(:kogen_groups, [])])
        await(id, finish, cancel)

      {:proto, %{"type" => "exec_done", "id" => ^id} = m} ->
        if cancel, do: cancelled(cancel)
        %{status: m["status"], output: m["output"], timed_out: m["timed_out"]}

      # Without kogen no exec_done comes: stop the groups here instead of waiting.
      {:proto, %{"type" => "cancel", "signal" => sig}} ->
        if finish and not :persistent_term.get(:kogen_eof, false),
          do: await(id, finish, sig),
          else: cancelled(sig)
    end
  end

  @doc "Throws `{:cancel, signal}` if the caller has interrupted."
  def check_cancel do
    receive do
      {:proto, %{"type" => "cancel", "signal" => sig}} -> cancelled(sig)
    after
      0 -> :ok
    end
  end

  def cancelled(sig) do
    if :persistent_term.get(:kogen_eof, false), do: stop_groups(Process.get(:kogen_groups, []))
    throw({:cancel, sig})
  end

  # SIGTERM to each command group, SIGKILL after 5 seconds to the ones still alive.
  defp stop_groups(groups) do
    signal = fn sig, g ->
      System.cmd("kill", ["-#{sig}", "--", "-#{g}"], stderr_to_stdout: true)
    end

    alive = for g <- groups, match?({_, 0}, signal.("TERM", g)), do: g

    Enum.reduce_while(1..50, alive, fn _, alive ->
      alive = for g <- alive, match?({_, 0}, signal.("0", g)), do: g

      if alive == [],
        do: {:halt, []},
        else:
          (
            Process.sleep(100)
            {:cont, alive}
          )
    end)
    |> Enum.each(&signal.("KILL", &1))
  end
end
