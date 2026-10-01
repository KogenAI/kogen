defmodule Kogen.Shaping.Notifier do
  @moduledoc """
  macOS notifications for a headless Shaping session. The status JSON stays
  the authority; a notification only points at it.

  `osascript -e 'display notification "<body>" with title "Kogen"'` shows
  it; with `KOGEN_SHAPING_NOTIFIER` set, that executable runs instead with
  one JSON argument (`{"session", "kind", "title", "body"}`), the test seam.
  A failure is logged to `events.jsonl` and otherwise ignored.
  """

  alias Kogen.Shaping.Store

  @doc "Notifies `kind` for the session in `dir` with `body`."
  def notify(dir, session, kind, body) do
    payload = %{
      "session" => session["intent_id"],
      "kind" => kind,
      "title" => "Kogen",
      "body" => body
    }

    result =
      try do
        case System.get_env("KOGEN_SHAPING_NOTIFIER") do
          nil -> System.cmd("osascript", ["-e", osascript(body)], stderr_to_stdout: true)
          "" -> System.cmd("osascript", ["-e", osascript(body)], stderr_to_stdout: true)
          executable -> System.cmd(executable, [Jason.encode!(payload)], stderr_to_stdout: true)
        end
      rescue
        error -> {Exception.message(error), 1}
      end

    case result do
      {_output, 0} ->
        Store.event!(dir, "notified", %{"kind" => kind, "body" => body})

      {output, status} ->
        Store.event!(dir, "notify_failed", %{"kind" => kind, "exit" => status, "output" => output})
    end

    :ok
  end

  defp osascript(body) do
    ~s(display notification "#{escape(body)}" with title "Kogen")
  end

  defp escape(text), do: text |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
end
