defmodule Kogen.Error do
  @moduledoc "A refusal or failure reported as `<class>/<reason>: <detail>` (CLI-6)."
  defexception [:class, :reason, :detail, lines: [], exit: 1]

  @impl true
  def message(e), do: "#{e.class}/#{e.reason}: #{e.detail}"

  def raise!(class, reason, detail, exit, lines \\ []) do
    raise __MODULE__, class: class, reason: reason, detail: detail, exit: exit, lines: lines
  end

  @doc "The error line plus its indented detail lines."
  def render(e),
    do: Enum.map_join([message(e) | Enum.map(e.lines, &("  " <> &1))], "", &(&1 <> "\n"))
end
