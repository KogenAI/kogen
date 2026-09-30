defmodule Kogen.ShapingAudit.Finding do
  @moduledoc """
  One Shaping audit finding, the string-keyed map stored as-is in `report.json`.

  Every finding has a stable id: its rule, plus its subject when the rule can
  fire more than once (`stale-anchor cited_bytes`). A `## Dispositions` entry
  "<id>: not a defect — <reason>" clears a disputable blocking finding; the
  mechanical set (Build's own admission predicates,
  `controller-read-path`, `edited-live-owner-unselected`, `title-format`,
  `commit-subject-format` and `package-invalid`) cannot be disputed away.
  """

  @mechanical ~w(
    unguarded-affected-path proof-selector-missing unsupported-selector unknown-target
    verified-by-invalid paid-reason-malformed controller-read-path
    edited-live-owner-unselected title-format commit-subject-format package-invalid
    recommendation-without-evidence assumption-without-reason
  )

  @doc "The rules that no disposition can clear."
  def mechanical, do: @mechanical

  @doc "Whether `rule` belongs to the undisputable mechanical set."
  def mechanical?(rule), do: rule in @mechanical

  @doc """
  A finding for `rule` about `subject` (`nil` when the rule fires once).
  `attrs` sets `layer`, `severity`, `scope`, `scenario`, `paths`, `message`,
  `route` and any extra key; `disputable` defaults to the mechanical set.
  """
  def new(rule, subject, attrs) when is_binary(rule) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    Map.merge(
      %{
        "id" => id(rule, subject),
        "rule" => rule,
        "layer" => "deterministic",
        "scope" => "draft",
        "severity" => "blocking",
        "disputable" => not mechanical?(rule),
        "scenario" => nil,
        "paths" => [],
        "message" => "",
        "route" => nil,
        "disposition" => nil
      },
      attrs
    )
  end

  @doc "The stable id of `rule` about `subject`."
  def id(rule, nil), do: rule
  def id(rule, subject), do: "#{rule} #{subject}"

  @doc "Attaches each finding's `## Dispositions` entry, keyed by finding id."
  def apply_dispositions(findings, dispositions) when is_map(dispositions) do
    Enum.map(findings, fn finding ->
      case Map.fetch(dispositions, finding["id"]) do
        {:ok, disposition} -> Map.put(finding, "disposition", disposition)
        :error -> finding
      end
    end)
  end

  @doc """
  Whether the finding still blocks readiness: it is blocking, and it is not a
  disputable finding dispositioned "not a defect". A fix-check that marked a
  "fixed" claim `still_open` keeps it blocking.
  """
  def open_blocking?(%{"severity" => "blocking"} = finding) do
    finding["still_open"] == true or not disputed?(finding)
  end

  def open_blocking?(_finding), do: false

  @doc "Whether a disputable finding carries a \"not a defect\" disposition."
  def disputed?(finding) do
    finding["disputable"] == true and
      match?(%{"kind" => "not-a-defect"}, finding["disposition"])
  end
end
