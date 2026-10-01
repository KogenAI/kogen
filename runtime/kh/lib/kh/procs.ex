defmodule Kh.Procs do
  @moduledoc """
  Session-keyed registry of OS process trees started by the runtime. On SIGTERM/SIGHUP kh kills them all before
  exiting. When /usr/bin/perl is available, Bash commands additionally monitor the VM process and clean up on its death, including SIGINT/SIGKILL. Other backend children still require parent process custody for untrappable exits.
  """
  @table :kh_procs

  def init, do: ensure_registry(3)

  defp ensure_registry(0), do: raise("cannot establish stable process registry")

  defp ensure_registry(attempts) do
    if :ets.whereis(@table) == :undefined do
      case GenServer.start(Kh.Procs.RegistryOwner, nil, name: Kh.Procs.RegistryOwner) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> raise "cannot start process registry owner: #{inspect(reason)}"
      end
    end

    # Concurrent sessions queue here if the named owner registered before its
    # init callback created the table.
    try do
      GenServer.call(Kh.Procs.RegistryOwner, :ensure_table, :infinity)
    catch
      :exit, _ -> ensure_registry(attempts - 1)
    end
  end

  def register(nil, _session_id, _bash_pgroup), do: :ok
  def register(pid, session_id, bash_pgroup), do: if(:ets.whereis(@table) != :undefined, do: :ets.insert(@table, {pid, session_id, bash_pgroup}))
  def unregister(nil, _session_id), do: :ok
  def unregister(pid, _session_id), do: if(:ets.whereis(@table) != :undefined, do: :ets.delete(@table, pid))

  def kill_session(session_id) when is_binary(session_id) do
    if :ets.whereis(@table) != :undefined do
      for {pid, ^session_id, bash_pgroup} <- :ets.tab2list(@table), do: Kh.Tools.Bash.kill_tree(pid, bash_pgroup)
    end

    :ok
  end

  def kill_all do
    if :ets.whereis(@table) != :undefined, do: for({pid, _session_id, bash_pgroup} <- :ets.tab2list(@table), do: Kh.Tools.Bash.kill_tree(pid, bash_pgroup))
    :ok
  end

  @doc "Kill registered trees and exit on SIGTERM/SIGHUP. Bash uses a separate OS monitor for SIGINT/SIGKILL; OTP cannot trap those signals."
  def trap_signals do
    init()
    System.trap_signal(:sigterm, fn -> kill_all(); System.halt(143) end)
    System.trap_signal(:sighup, fn -> kill_all(); System.halt(129) end)
    :ok
  end
end

defmodule Kh.Procs.RegistryOwner do
  @moduledoc false
  use GenServer

  @table :kh_procs

  def init(nil) do
    create_table()
    {:ok, nil}
  end

  def handle_call(:ensure_table, _from, state) do
    create_table()
    {:reply, :ok, state}
  end

  defp create_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    :ok
  end
end
