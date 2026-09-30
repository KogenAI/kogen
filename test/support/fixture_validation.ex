defmodule Kogen.FixtureValidation do
  @moduledoc """
  Provider-denied validation of generated live-target fixtures.

  Lives in `test/support` (not `lib`): it is offline-gate tooling for the
  fixture generators that also live there, it reaches Kogen's real parsers
  (`Kogen.Intent`, `Kogen.Build.Contract`, YamlElixir) without adding a
  Boundary-declared runtime module, and it never ships in a release.

  A validation takes the generated fixture directory exactly as the live
  target will consume it and a spec naming what must exist and parse:

    * `required` -- files that must exist as regular files;
    * `yaml` / `json` -- files that must parse (a JSON document is YAML);
    * `approved` -- an Approved package directory (relative) that must pass
      the Approved-package parsers: `intent.yaml`, `scenarios.yaml`,
      `risks.yaml` all present and parseable, `Kogen.Intent.read/2`, and
      `Kogen.Build.Contract.load/2` against the fixture's own Makefile;
    * `makefile_targets` -- targets the fixture Makefile must declare;
    * `readme_links` -- a README whose relative links must resolve;
    * `input_receipt` -- a `complete-input-receipt.json` whose recorded
      hashes must equal the files on disk;
    * `draft` -- a Draft slug whose `intent.yaml` must carry the identity
      and provenance fields `Kogen.Intent.read_draft/1` requires, plus a
      `frozen-hashes.json` sibling (optional `seed` directory) that must match.

  A spec may name `digest_exclude` paths for generated files that embed
  run-specific values (paths, timestamps); they are still validated as
  required files but do not enter the digest.

  It returns a record carrying a deterministic digest over the fixture's
  input bytes (`digest/1`) so the bytes a target later consumes can be
  compared with the bytes that were validated. Generation itself happens
  with providers denied (`require_denied!/0`); a validation performed while
  provider access is open is not a valid rehearsal.
  """

  alias Kogen.Build.Contract
  alias Kogen.Intent

  @volatile ~w(.git _build deps .kogen/runtime .kogen/build.lock cover .elixir_ls)
  @record_tag "KOGEN_FIXTURE_VALIDATION"

  @doc "Tag of the one stdout line `main/0` prints on success."
  def record_tag, do: @record_tag

  @doc "True when the environment says provider access is denied."
  def denied?(getter \\ &System.get_env/1), do: getter.("KOGEN_PROVIDERS_DENIED") in ["1", "true"]

  @doc "Raises unless the process runs with provider access denied."
  def require_denied!(getter \\ &System.get_env/1) do
    unless denied?(getter), do: raise("fixture validation requires KOGEN_PROVIDERS_DENIED=1")
    :ok
  end

  @doc """
  Deterministic sha256 over every regular file and symlink under `dir`
  (relative path plus content hash; symlinks by target), excluding volatile
  controller state. Independent of file order, mtimes and the fixture's
  absolute location.
  """
  def digest(dir, exclude \\ []) do
    dir
    |> tree_entries(exclude)
    |> Enum.map_join("\n", fn {relative, hash} -> relative <> "\t" <> hash end)
    |> sha256()
  end

  @doc "Sorted `{relative_path, sha256}` entries `digest/1` covers."
  def tree_entries(dir, exclude \\ []) do
    dir
    |> walk("", exclude)
    |> Enum.sort()
  end

  defp walk(root, relative, exclude) do
    path = Path.join(root, relative)

    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        for name <- File.ls!(path),
            child = Path.join(relative, name) |> String.trim_leading("/"),
            not volatile?(child),
            child not in exclude,
            entry <- walk(root, child, exclude),
            do: entry

      {:ok, %{type: :regular}} ->
        [{relative, sha256(File.read!(path))}]

      {:ok, %{type: :symlink}} ->
        [{relative, "symlink:" <> sha256(inspect(File.read_link!(path)))}]

      _ ->
        []
    end
  end

  defp volatile?(relative), do: Enum.any?(@volatile, &(relative == &1))

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @doc """
  Validates `dir` against `spec` (a map with string or atom keys, see the
  moduledoc). Returns `{:ok, record}` or `{:error, [reason]}` naming every
  failure, never stopping at the first.
  """
  def validate(dir, spec) do
    spec = Map.new(spec, fn {key, value} -> {to_string(key), value} end)

    reasons =
      List.flatten([
        check_required(dir, List.wrap(spec["required"])),
        check_parse(dir, List.wrap(spec["yaml"]), :yaml),
        check_parse(dir, List.wrap(spec["json"]), :json),
        check_approved(dir, spec["approved"]),
        check_makefile(dir, List.wrap(spec["makefile_targets"])),
        check_links(dir, spec["readme_links"]),
        check_input_receipt(dir, spec["input_receipt"]),
        check_draft(dir, spec["draft"])
      ])

    excluded = List.wrap(spec["digest_exclude"])

    case reasons do
      [] ->
        {:ok,
         %{
           "schema_version" => 1,
           "kind" => spec["kind"],
           "label" => spec["label"],
           "providers_denied" => denied?(),
           "digest" => digest(dir, excluded),
           "files" => length(tree_entries(dir, excluded))
         }}

      reasons ->
        {:error, reasons}
    end
  end

  defp check_required(dir, required) do
    for relative <- required, not File.regular?(Path.join(dir, relative)) do
      "required fixture file is missing: #{relative}"
    end
  end

  defp check_parse(dir, files, kind) do
    for relative <- files, path = Path.join(dir, relative), File.regular?(path) do
      case parse(File.read!(path), kind) do
        {:ok, _} -> []
        {:error, reason} -> "#{relative} is not valid #{kind}: #{reason}"
      end
    end
    |> List.flatten()
  end

  defp parse(text, :yaml) do
    case YamlElixir.read_from_string(text) do
      {:ok, value} when not is_nil(value) -> {:ok, value}
      {:ok, nil} -> {:error, "document is empty"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, inspect({kind, reason})}
  end

  defp parse(text, :json) do
    case Jason.decode(text) do
      {:ok, value} -> {:ok, value}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp check_approved(_dir, nil), do: []

  defp check_approved(dir, relative) do
    package = Path.join(dir, relative)
    slug = Path.basename(package)

    files = ~w(intent.yaml scenarios.yaml risks.yaml)

    missing =
      for name <- files,
          not File.regular?(Path.join(package, name)),
          do: "Approved package file is missing: #{relative}/#{name}"

    if missing != [] do
      missing
    else
      parsed =
        for name <- files,
            {:error, reason} <- [parse(File.read!(Path.join(package, name)), :yaml)],
            do: "#{relative}/#{name} is not valid yaml: #{reason}"

      if parsed != [] do
        parsed
      else
        approved_parsers(dir, package, slug)
      end
    end
  end

  defp approved_parsers(dir, package, slug) do
    intent =
      case Intent.read(slug, Path.dirname(package)) do
        {:ok, _} -> []
        {:error, reason} -> ["Kogen.Intent.read rejected the package: #{reason}"]
      end

    contract =
      case Contract.load(package, dir) do
        {:ok, %{scenarios: [_ | _]}} -> []
        {:ok, _} -> ["Kogen.Build.Contract.load returned no scenarios"]
        {:error, reason} -> ["Kogen.Build.Contract.load rejected the package: #{reason}"]
      end

    intent ++ contract
  end

  defp check_makefile(_dir, []), do: []

  defp check_makefile(dir, targets) do
    case File.read(Path.join(dir, "Makefile")) do
      {:ok, text} ->
        for target <- targets,
            not Regex.match?(~r/^#{Regex.escape(target)}:/m, text),
            do: "Makefile does not declare target #{target}"

      {:error, _} ->
        ["Makefile is missing"]
    end
  end

  defp check_links(_dir, nil), do: []

  defp check_links(dir, readme) do
    case File.read(Path.join(dir, readme)) do
      {:ok, text} ->
        for [_, link] <- Regex.scan(~r/\[[^\]]+\]\(([^)]+)\)/, text),
            not String.contains?(link, "://"),
            not File.regular?(Path.join(dir, link)),
            do: "#{readme} links to a missing file: #{link}"

      {:error, _} ->
        ["#{readme} is missing"]
    end
  end

  defp check_input_receipt(_dir, nil), do: []

  defp check_input_receipt(dir, relative) do
    with {:ok, text} <- File.read(Path.join(dir, relative)),
         {:ok, %{"inputs" => [_ | _] = inputs}} <- Jason.decode(text) do
      for %{"path" => path, "sha256" => hash} <- inputs,
          actual = read_hash(Path.join(dir, path)),
          actual != hash,
          do:
            "#{relative} records #{path} as #{hash} but the fixture holds #{actual || "nothing"}"
    else
      _ -> ["#{relative} is missing, unparsable or lists no inputs"]
    end
  end

  defp read_hash(path) do
    case File.read(path) do
      {:ok, bytes} -> sha256(bytes)
      {:error, _} -> nil
    end
  end

  defp check_draft(_dir, nil), do: []

  defp check_draft(dir, %{"slug" => slug} = draft) do
    path = Path.join([dir, ".kogen/intents/drafts", slug])
    fields = %{"shaped_against" => ~w(branch head), "shaping" => ~w(harness model effort started)}

    with {:ok, text} <- File.read(Path.join(path, "intent.yaml")),
         {:ok, intent} when is_map(intent) <- parse(text, :yaml) do
      identity =
        for key <- ~w(id slug),
            not (is_binary(intent[key]) and intent[key] != ""),
            do: "draft intent.yaml lacks #{key}"

      slug_match = if intent["slug"] == slug, do: [], else: ["draft intent.yaml slug mismatch"]

      provenance =
        for {key, names} <- fields,
            name <- names,
            not (is_map(intent[key]) and intent[key][name] not in [nil, ""]),
            do: "draft intent.yaml lacks #{key}.#{name}"

      identity ++ slug_match ++ provenance ++ check_scenarios(path) ++ check_frozen(draft, path)
    else
      _ -> ["draft intent.yaml under #{slug} is missing or invalid"]
    end
  end

  defp check_scenarios(path) do
    case File.read(Path.join(path, "scenarios.yaml")) do
      {:ok, text} ->
        case parse(text, :yaml) do
          {:ok, [_ | _]} -> []
          _ -> ["draft scenarios.yaml is invalid or empty"]
        end

      _ ->
        ["draft scenarios.yaml is missing"]
    end
  end

  defp check_frozen(%{"frozen" => seed}, path) when is_binary(seed) do
    with {:ok, text} <- File.read(Path.join(seed, "frozen-hashes.json")),
         {:ok, hashes} when is_map(hashes) <- Jason.decode(text) do
      for {relative, hash} <- hashes,
          actual = read_hash(Path.join(path, relative)),
          actual != hash,
          do: "draft file #{relative} differs from its frozen hash"
    else
      _ -> ["draft frozen-hashes.json is missing or invalid"]
    end
  end

  defp check_frozen(_draft, _path), do: []

  @doc "Appends one record as a JSON line to the receipt at `path`."
  def append_record!(path, record) do
    File.write!(path, Jason.encode!(record) <> "\n", [:append])
  end

  @doc "Reads the JSON-line records a validation receipt holds (missing file: `[]`)."
  def read_records(path) do
    case File.read(path) do
      {:ok, text} ->
        text |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

      {:error, _} ->
        []
    end
  end

  @doc """
  CLI entry point for generators in other languages:
  `mix run --no-start -r test/support/fixture_validation.ex -e
  'Kogen.FixtureValidation.main()' -- SPEC.json`. The spec JSON carries
  `root` plus the `validate/2` keys, and `require_denied: true` when the
  caller is a provider-denied prepare. On success prints one
  `KOGEN_FIXTURE_VALIDATION\\t<json>` line, appends it to
  `KOGEN_FIXTURE_VALIDATION_RECEIPT` when set, and exits 0; otherwise prints
  each reason to stderr and exits 1 (a Candidate-caused `offline` failure,
  never an environment or provider one).
  """
  def main(argv \\ System.argv()) do
    [spec_path | _] = argv
    spec = spec_path |> File.read!() |> Jason.decode!()
    root = Map.fetch!(spec, "root")
    if spec["require_denied"] == true, do: require_denied!()

    case validate(root, Map.drop(spec, ["root", "require_denied"])) do
      {:ok, record} ->
        IO.puts(@record_tag <> "\t" <> Jason.encode!(record))

        if path = System.get_env("KOGEN_FIXTURE_VALIDATION_RECEIPT"),
          do: append_record!(path, record)

        System.halt(0)

      {:error, reasons} ->
        for reason <- reasons, do: IO.puts(:stderr, "fixture validation failed: " <> reason)
        System.halt(1)
    end
  end
end
