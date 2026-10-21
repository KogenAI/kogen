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

    with {:ok, bytes} <- File.read(Intent.approval_path(root, slug)),
         {:ok, approval} <- JSON.decode(bytes) do
      Kogen.SourceProvenance.validate_bound!(approval["source_provenance"])
    end

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
    source = Kogen.SourceProvenance.binding(root, slug, before)
    ready = Readiness.cached(root, slug, config) || Readiness.check!(root, slug, config)
    baseline = Intent.baseline(root, slug, config)
    sha = Intent.hash(root, baseline)
    if hash && sha != before, do: mismatch!(slug, sha, hash)

    if not Readiness.current?(root, slug, config, ready),
      do: Error.raise!("intent", "not_ready", "readiness inputs changed; review again", 1)

    Kogen.SourceProvenance.validate_bound!(source)

    unless Kogen.SourceProvenance.binding(root, slug, sha) == source do
      Error.raise!(
        "candidate",
        "source_provenance_changed",
        "source provenance changed during readiness; inspect the receipt and review again before exact approval",
        1
      )
    end

    cond do
      hash == nil ->
        Bridge.puts(Kogen.SourceProvenance.card(source))
        card(slug, sha, approver, ready, baseline)

      true ->
        path = Intent.approval_path(root, slug)
        File.mkdir_p!(Path.dirname(path))
        approved_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

        previous = File.read(path)

        try do
          File.write!(
            path,
            JSON.encode!(%{
              "slug" => slug,
              "sha256" => sha,
              "approver" => approver,
              "approved_at" => approved_at,
              "source_provenance" => source
            }) <> "\n"
          )

          unless Readiness.current?(root, slug, config, ready),
            do:
              Error.raise!(
                "intent",
                "not_ready",
                "readiness inputs changed during approval publication",
                1
              )
        rescue
          error ->
            case previous do
              {:ok, bytes} -> File.write!(path, bytes)
              {:error, :enoent} -> File.rm(path)
            end

            reraise error, __STACKTRACE__
        catch
          {:cancel, signal} ->
            case previous do
              {:ok, bytes} -> File.write!(path, bytes)
              {:error, :enoent} -> File.rm(path)
            end

            throw({:cancel, signal})
        end

        Kogen.LocalFacts.package(root, slug, config)
        Bridge.puts("approved #{slug} #{String.slice(sha, 0, 8)}")
        Bridge.puts("Next: kogen intent build #{slug}")
        0
    end
  end

  defp mismatch!(slug, sha, prefix) do
    Error.raise!(
      "intent",
      "hash_mismatch",
      "#{slug} is now #{String.slice(sha, 0, 8)}, not #{prefix}; review it again with kogen intent approve #{slug}",
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

    Bridge.puts("Files")
    for p <- baseline, do: Bridge.puts("  - #{p}")
    Bridge.puts("Approve with:")
    Bridge.puts("  kogen intent approve #{slug} #{String.slice(sha, 0, 8)}")
    5
  end
end
