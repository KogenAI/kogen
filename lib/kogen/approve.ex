defmodule Kogen.Approve do
  @moduledoc """
  `kogen intent approve <slug> [<hash>]` (AUT-1, AUT-2): without a hash, obtain current readiness and
  print the review card; with a hash that matches the acceptance baseline, reuse successful shaping, published refinement or card evidence for the same baseline hash and HEAD or check readiness again. Approval never starts a Build.
  """
  alias Kogen.{Bridge, Build, Config, Error, Git, Intent, Lock, Readiness}

  def run(project, slug, hash, by) do
    root = Git.root!(project)
    lock = Build.lock!(root)

    try do
      approve(root, slug, hash, by)
    after
      Lock.release(lock)
    end
  end

  defp approve(root, slug, hash, by) do
    config = Config.load!(root)
    questions_pending!(root, slug)
    Intent.exists!(root, slug)

    previous = File.read(Intent.approval_path(root, slug))

    approval =
      case previous do
        {:ok, bytes} -> JSON.decode!(bytes)
        {:error, :enoent} -> nil
      end

    pinned = Kogen.SourceProvenance.resolve_approval!(root, slug, approval)

    approver =
      by || Git.identity(root) ||
        Error.raise!(
          "intent",
          "approval_identity_unavailable",
          "configure git user.name and user.email, or pass --by <name>",
          2
        )

    baseline = Intent.baseline(root, slug, config)
    before = Intent.hash(root, baseline)
    if hash && not String.starts_with?(before, hash), do: mismatch!(slug, before, hash)
    source = Kogen.SourceProvenance.binding(root, slug)
    ready = Readiness.cached(root, slug, config) || Readiness.check!(root, slug, config)
    baseline = Intent.baseline(root, slug, config)
    sha = Intent.hash(root, baseline)
    if hash && sha != before, do: mismatch!(slug, sha, hash)

    if not Readiness.current?(root, slug, config, ready),
      do: Error.raise!("intent", "not_ready", "readiness inputs changed; review again", 1)

    Kogen.SourceProvenance.validate_bound!(source)

    unless Kogen.SourceProvenance.binding(root, slug) == source do
      Error.raise!(
        "candidate",
        "source_provenance_changed",
        "source provenance changed during readiness: #{Kogen.SourceProvenance.path(root, slug)}; restore exact custody from preserved native receipt history, then run the card",
        1
      )
    end

    Kogen.SourceProvenance.validate_bound!(pinned)

    unless File.read(Intent.approval_path(root, slug)) == previous,
      do:
        Error.raise!(
          "intent",
          "not_ready",
          "approval changed during readiness; run the card again",
          1
        )

    cond do
      hash == nil ->
        if approval && approval["sha256"] != sha,
          do:
            Bridge.puts(
              "Stale approval: #{approval["sha256"]}; it does not authorize the current package #{sha}."
            )

        if source && source["contract_sha256"] != sha,
          do:
            Bridge.puts(
              "Historical source receipt contract: #{source["contract_sha256"]}; current contract: #{sha}. Shape has not run again."
            )

        Bridge.puts(Kogen.SourceProvenance.card(source))
        card(slug, sha, approver, ready, baseline)

      true ->
        path = Intent.approval_path(root, slug)
        File.mkdir_p!(Path.dirname(path))
        approved_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

        if approval && approval["sha256"] != sha,
          do: archive_approval!(root, slug, elem(previous, 1))

        previous_source = if source, do: File.read!(source["path"])
        published_source = Kogen.SourceProvenance.refresh(root, slug, sha, source)

        bytes =
          JSON.encode!(%{
            "slug" => slug,
            "sha256" => sha,
            "approver" => approver,
            "approved_at" => approved_at,
            "source_provenance" => published_source
          }) <> "\n"

        try do
          Kogen.SourceProvenance.validate_bound!(
            pinned_before_refresh(pinned, source, published_source)
          )

          unless File.read(path) == previous,
            do:
              Error.raise!(
                "intent",
                "not_ready",
                "approval changed during publication; run the card again",
                1
              )

          File.write!(path, bytes)
          Bridge.check_cancel()
          Kogen.SourceProvenance.validate_bound!(published_source)

          unless Readiness.current?(root, slug, config, ready),
            do:
              Error.raise!(
                "intent",
                "not_ready",
                "readiness inputs changed during approval publication",
                1
              )

          Kogen.SourceProvenance.validate_bound!(published_source)

          Kogen.SourceProvenance.validate_bound!(
            pinned_before_refresh(pinned, source, published_source)
          )

          unless Kogen.SourceProvenance.binding(root, slug) == published_source and
                   File.read(path) == {:ok, bytes},
                 do:
                   Error.raise!(
                     "intent",
                     "not_ready",
                     "source or approval changed during publication; inspect the changed custody before running the card",
                     1
                   )

          Bridge.check_cancel()
        rescue
          error ->
            rollback(path, bytes, previous, published_source, previous_source)
            reraise error, __STACKTRACE__
        catch
          {:cancel, signal} ->
            rollback(path, bytes, previous, published_source, previous_source)
            throw({:cancel, signal})
        end

        Kogen.LocalFacts.package(root, slug, config)
        Bridge.puts("approved #{slug} #{String.slice(sha, 0, 8)}")
        Bridge.puts("Next: kogen intent build #{slug}")
        0
    end
  end

  # Refresh intentionally moves current custody; validate that pinned predecessor
  # via its immutable hash-named history after that publication.
  defp pinned_before_refresh(pinned, source, published) do
    if pinned != nil and pinned == source and source != published,
      do:
        Map.put(
          pinned,
          "path",
          Path.join(Path.dirname(pinned["path"]), pinned["sha256"] <> ".json")
        ),
      else: pinned
  end

  defp rollback(path, bytes, previous, published, original) do
    Kogen.SourceProvenance.restore(published, original)

    if File.read(path) == {:ok, bytes} do
      case previous do
        {:ok, old} -> File.write!(path, old)
        {:error, :enoent} -> File.rm(path)
      end
    end
  end

  defp archive_approval!(root, slug, bytes) do
    for relative <- [
          ".kogen",
          ".kogen/local",
          ".kogen/local/approvals",
          ".kogen/local/approvals/history",
          ".kogen/local/approvals/history/#{slug}"
        ] do
      dir = Path.join(root, relative)

      case File.lstat(dir) do
        {:error, :enoent} ->
          File.mkdir!(dir)

        {:ok, %{type: :directory}} ->
          :ok

        _ ->
          Error.raise!(
            "candidate",
            "source_provenance_changed",
            "unsafe approval history: #{dir}; restore exact private history, then run the card",
            1
          )
      end

      if String.contains?(relative, "/history"), do: File.chmod!(dir, 0o700)
    end

    archive =
      Path.join(
        root,
        ".kogen/local/approvals/history/#{slug}/#{Kogen.WorkingContext.hash(bytes)}.json"
      )

    case File.lstat(archive) do
      {:error, :enoent} ->
        File.write!(archive, bytes, [:exclusive])

      {:ok, %{type: :regular}} ->
        unless File.read!(archive) == bytes,
          do:
            Error.raise!(
              "candidate",
              "source_provenance_changed",
              "restore exact approval history: #{archive}",
              1
            )

      _ ->
        Error.raise!(
          "candidate",
          "source_provenance_changed",
          "unsafe approval history: #{archive}; restore exact history, then run the card",
          1
        )
    end

    File.chmod!(archive, 0o600)
    Bridge.puts("Retained stale approval: #{archive}")
  end

  defp mismatch!(slug, sha, prefix) do
    Error.raise!(
      "intent",
      "hash_mismatch",
      "#{slug} is now #{sha}, not #{prefix}; review it again with kogen intent approve #{slug}",
      1
    )
  end

  defp questions_pending!(root, slug) do
    case File.read(Path.join(root, ".kogen/local/shaping/#{slug}/state.json")) do
      {:ok, text} ->
        round = text |> JSON.decode!() |> Map.fetch!("rounds") |> List.last()
        n = length(round["questions"]) - map_size(round["answers"] || %{})

        if n > 0 do
          Error.raise!(
            "intent",
            "questions_pending",
            "#{slug} has #{n} unanswered question(s); answer them with kogen intent shape #{slug} <file|->",
            5
          )
        end

      {:error, _} ->
        :ok
    end
  end

  defp card(slug, sha, approver, ready, baseline) do
    Bridge.puts("Intent: #{slug} — #{ready.intent.title}")
    Bridge.puts("SHA-256: #{sha}")
    Bridge.puts("Approver: #{approver}")
    Bridge.puts("")
    Bridge.puts("Acceptance")

    ready.scenarios
    |> Enum.chunk_by(fn s -> Map.get(s, :outline_line) || {:scenario, s.line} end)
    |> Enum.each(fn [s | group] ->
      examples = Map.get(s, :outline_examples)
      name = Map.get(s, :outline_name, s.name)

      status =
        if Enum.any?([s | group], &(&1.status == "failed")), do: "fails now", else: "passes now"

      count = if examples, do: " (#{examples} examples)", else: ""
      Bridge.puts("  - #{name}#{count} (#{status})")
    end)

    observations = Readiness.observations(slug, ready)
    if observations != "", do: Bridge.puts("\n" <> observations <> "\n")

    {:ok, stages} = Kogen.Stages.parse(ready.intent.text)

    if stages do
      Bridge.puts("Staged plan")

      for {stage, index} <- Enum.with_index(stages, 1) do
        Bridge.puts("  #{index}. #{stage["title"]} (#{stage["id"]}): #{stage["goal"]}")
        for cmd <- stage["checks"], do: Bridge.puts("    - #{cmd}")
      end
    end

    Bridge.puts("Files")
    for p <- baseline, do: Bridge.puts("  - #{p}")
    Bridge.puts("Approve with:")
    Bridge.puts("  kogen intent approve #{slug} #{sha}")
    5
  end
end
