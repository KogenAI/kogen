defmodule Kogen.Application do
  @moduledoc """
  The supervised application. Each `kogen` invocation runs one short-lived core
  (`Kogen.Main.main/0` in the release's eval mode); it supervises no long-running processes.
  """
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([], strategy: :one_for_one, name: Kogen.Supervisor)
  end
end
