defmodule Kogen.Shaping.Draft do
  @moduledoc """
  What the engine reads from the session's package: where it is, its open
  `## Ask the Shaper` entries, and which inputs `## Shaper answers` records
  (by a reversible byte-exact frame checked against the accepted session
  input). Recording is computed from the Draft and session inputs every time.
  """

  alias Kogen.ShapingAudit.{HeadlessInput, Package, Questions}

  @doc "`{:ok, %{slug, package_rel, location}}` or `:none`."
  def locate(root, intent_id) do
    case Package.find_by_id(root, intent_id) do
      {:ok, found} -> {:ok, found}
      _other -> :none
    end
  end

  @doc "The package's current `questions.md` text, or `nil`."
  def questions_text(root, %{package_rel: rel}) do
    case File.read(Path.join([root, rel, "questions.md"])) do
      {:ok, text} -> text
      {:error, _reason} -> nil
    end
  end

  def questions_text(_root, _package), do: nil

  @doc "Open `## Ask the Shaper` entries as status maps."
  def open_questions(text) do
    text
    |> Questions.parse()
    |> Questions.entries("Ask the Shaper")
    |> Enum.map(fn entry ->
      %{
        "number" => entry.number,
        "question" => entry.fields["Question"] || entry.title || entry.text,
        "recommendation" => entry.fields["Recommendation"],
        "evidence" => entry.fields["Evidence"]
      }
    end)
  end

  @doc "Input IDs recorded exactly under `## Shaper answers`, checked against canonical inputs."
  def recorded(text, inputs), do: HeadlessInput.recorded(text, inputs)

  @doc "Loads the package bytes and revision."
  def load(root, %{package_rel: rel}), do: Package.load(root, rel)

  @doc "The package's current revision, or `nil`."
  def revision(root, package) do
    case load(root, package) do
      {:ok, %{revision: revision}} -> revision
      _error -> nil
    end
  end

  @doc "Every slug under `drafts/` and `approved/`."
  def slugs(root) do
    for kind <- ["drafts", "approved"],
        path <- Path.wildcard(Path.join([root, ".kogen/intents", kind, "*"])),
        File.dir?(path),
        uniq: true,
        do: Path.basename(path)
  end
end
