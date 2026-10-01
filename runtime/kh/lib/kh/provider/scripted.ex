defmodule Kh.Provider.Scripted do
  @moduledoc "A strict, session-local offline provider. It never opens a network connection."
  @behaviour Kh.Provider

  @impl true
  def stream(model, system, messages, tools, opts) do
    request = %{
      "model" => model.id,
      "effort_sent" => opts[:effort_sent],
      "session_id" => opts.session_id,
      "system" => system,
      "messages" => messages,
      "tool_names" => Enum.map(tools, & &1.name)
    }

    case opts[:session_server] do
      pid when is_pid(pid) -> Kh.Session.scripted_request(pid, opts.run_ref, request)
      _ -> {:error, {:fatal, "scripted provider requires its owning Kh.Session"}}
    end
  rescue
    _ -> {:error, {:fatal, "scripted provider session is unavailable"}}
  catch
    :exit, _ -> {:error, {:fatal, "scripted provider session is unavailable"}}
  end
end
