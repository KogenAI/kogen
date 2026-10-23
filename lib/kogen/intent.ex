defmodule Kogen.Intent do
  @moduledoc """
  An Intent: `.kogen/intents/<slug>/` with `intent.md`, `acceptance.feature` and an optional
  `model.qnt`, plus the step files its `Acceptance:` list names (chapter 02). Also its rules
  (SHP-5), its acceptance baseline and hash (VER-1, AUT-2) and its approval (AUT-2).
  """
  alias Kogen.{Config, Error, Gherkin, Git}

  defstruct [
    :slug,
    :slug_line,
    :root,
    :overlay,
    :title,
    :model,
    :acceptance,
    :decisions,
    :feasibility,
    :tests,
    :text
  ]

  @forbidden_tags ~w(@skip @wip @pending @manual @ignore)

  def dir(slug), do: ".kogen/intents/#{slug}"
  def feature(slug), do: dir(slug) <> "/acceptance.feature"
  def intent_md(slug), do: dir(slug) <> "/intent.md"
  def model_path(slug), do: dir(slug) <> "/model.qnt"

  def exists?(root, slug), do: File.exists?(Path.join(root, intent_md(slug)))

  def exists!(root, slug) do
    if not File.dir?(Path.join(root, dir(slug))),
      do: Error.raise!("intent", "not_found", "Intent does not exist", 2)
  end

  @doc "Reads intent.md. Returns the struct; fields are nil when their line is missing."
  def read(root, slug, overlay \\ %{}) do
    {:ok, text} = fetch(root, overlay, intent_md(slug))
    lines = String.split(text, "\n")

    %__MODULE__{
      slug: slug,
      root: root,
      overlay: overlay,
      text: text,
      title: Enum.find_value(lines, fn l -> match_prefix(l, "# ") end),
      model: Enum.find_value(lines, &match_prefix(&1, "Model:")),
      acceptance: list_after(lines, "Acceptance:"),
      decisions: section(lines, "## Decisions"),
      feasibility: section(lines, "## Feasibility"),
      tests: section(lines, "## Tests")
    }
    |> Map.update!(:model, &(&1 && String.trim(&1)))
    |> then(fn i -> %{i | title: i.title && String.trim(i.title)} end)
    |> Map.put(:slug_line, Enum.find_value(lines, &match_prefix(&1, "Slug:")))
  end

  defp match_prefix(line, prefix),
    do: if(String.starts_with?(line, prefix), do: String.replace_prefix(line, prefix, ""))

  defp list_after(lines, header) do
    case Enum.drop_while(lines, &(String.trim(&1) != header)) do
      [] ->
        nil

      [_ | rest] ->
        rest
        |> Enum.drop_while(&(String.trim(&1) == ""))
        |> Enum.take_while(&String.starts_with?(&1, "- "))
        |> Enum.map(&String.trim(String.replace_prefix(&1, "- ", "")))
    end
  end

  defp section(lines, header) do
    case Enum.drop_while(lines, &(String.trim(&1) != header)) do
      [] ->
        nil

      [_ | rest] ->
        rest
        |> Enum.take_while(&(not String.starts_with?(&1, "#")))
        |> Enum.filter(&String.starts_with?(&1, "- "))
    end
  end

  @doc """
  The parsed model line: `:none` for `not applicable — <reason>`, or
  `%{path, invariants, seed, samples, steps}`; nil when it cannot be read.
  """
  def model(%__MODULE__{model: nil}), do: nil

  def model(%__MODULE__{model: line}) do
    cond do
      Regex.match?(~r/^not applicable\s*[—-]\s*\S/u, line) ->
        :none

      m =
          Regex.run(
            ~r/^(\S+\.qnt) invariants=([A-Za-z_][A-Za-z0-9_]*(?:,[A-Za-z_][A-Za-z0-9_]*)*) seed=(\d+) samples=(\d+) steps=(\d+)$/,
            line
          ) ->
        [_, path, invs, seed, samples, steps] = m

        %{
          path: path,
          invariants: String.split(invs, ","),
          seed: seed,
          samples: samples,
          steps: steps
        }

      true ->
        nil
    end
  end

  @doc "The step files and other acceptance files after the feature."
  def step_files(%__MODULE__{acceptance: list, slug: slug}),
    do: Enum.reject(list || [], &(&1 == feature(slug)))

  @doc """
  Checks the SHP-5 rules. Returns `{:ok, intent, scenarios}` or `{:parse | :lint, problems}`.
  """
  def check(root, slug, overlay \\ %{}) do
    with {:ok, _} <- fetch(root, overlay, intent_md(slug)),
         intent = read(root, slug, overlay),
         {:ok, text} <-
           fetch(root, overlay, feature(slug)) |> or_parse("acceptance.feature does not exist"),
         {:ok, scenarios} <- Gherkin.parse(text) |> gherkin_problem() do
      case lint(intent, scenarios) do
        [] -> {:ok, intent, scenarios}
        problems -> {:lint, problems}
      end
    else
      {:error, :enoent} -> {:parse, ["intent.md does not exist"]}
      {:parse, problems} -> {:parse, problems}
    end
  end

  defp or_parse({:ok, t}, _), do: {:ok, t}
  defp or_parse(_, msg), do: {:parse, [msg]}

  defp gherkin_problem({:ok, s}), do: {:ok, s}
  defp gherkin_problem({:error, n, msg}), do: {:parse, ["acceptance.feature line #{n}: #{msg}"]}

  defp lint(i, scenarios) do
    root = i.root

    title =
      cond do
        i.title in [nil, ""] -> ["title: intent.md must start with a # title"]
        String.length(i.title) > 50 -> ["title: the title must be at most 50 characters"]
        String.ends_with?(i.title, ".") -> ["title: the title must not end with a period"]
        true -> []
      end

    slug =
      if (i.slug_line && String.trim(i.slug_line)) == i.slug,
        do: [],
        else: ["slug: the Slug: line must be #{i.slug}"]

    model =
      case model(i) do
        nil ->
          [
            "model: the Model: line must be `not applicable — <reason>` or `#{model_path(i.slug)} invariants=<Name> seed=<n> samples=<n> steps=<n>`"
          ]

        :none ->
          []

        m ->
          model_problems(i, m)
      end

    feature = feature(i.slug)

    acceptance =
      case i.acceptance do
        [^feature | _] = list ->
          ignored = ignored(root, list)

          Enum.flat_map(list, fn p ->
            cond do
              not (Map.has_key?(i.overlay, p) or File.regular?(Path.join(root, p))) ->
                ["acceptance: #{p} does not exist"]

              p in ignored ->
                ["acceptance: #{p} is ignored by Git"]

              true ->
                []
            end
          end)

        _ ->
          ["acceptance: the Acceptance: list must start with #{feature(i.slug)}"]
      end

    decisions =
      if Enum.all?(
           i.decisions || [],
           &Regex.match?(~r/\(source: (request|answer \d+)\)\s*$/, &1)
         ),
         do: [],
         else: ["decisions: a decision has no source"]

    tests =
      case i.tests do
        t when t in [nil, []] ->
          ["tests: the ## Tests section is missing or empty"]

        lines ->
          for l <- lines,
              not Regex.match?(
                ~r/^- (none: \S.*|.+: .+ \((unit|integration|scenario|regression|existing)\))$/,
                l
              ),
              do:
                "tests: #{l} must be `- <rule>: <test to add or update> (<layer>)` or `- none: <reason>`"
      end

    feasibility =
      if i.feasibility in [nil, []],
        do: [
          "feasibility: intent.md needs a ## Feasibility section listing each probe, or - none"
        ],
        else: []

    scen =
      if scenarios == [] do
        ["acceptance: acceptance.feature has no scenario"]
      else
        Enum.flat_map(scenarios, fn s ->
          tagged =
            for t <- s.tags,
                t in @forbidden_tags,
                do: "acceptance: scenario #{s.name} is tagged #{t}"

          if then?(s.steps),
            do: tagged,
            else: tagged ++ ["acceptance: scenario #{s.name} has no Then step"]
        end)
        |> Enum.uniq()
      end

    stages =
      case Kogen.Stages.parse(i.text) do
        {:ok, _} -> []
        {:error, problem} -> [problem]
      end

    title ++ slug ++ model ++ tests ++ acceptance ++ decisions ++ feasibility ++ scen ++ stages
  end

  defp then?(steps), do: Enum.any?(steps, &(&1.keyword == "Then "))

  defp model_problems(i, m) do
    expected = model_path(i.slug)

    case fetch(i.root, i.overlay, m.path) do
      _ when m.path != expected ->
        ["model: the model must be #{expected}"]

      {:error, _} ->
        ["model: #{m.path} does not exist"]

      {:ok, text} ->
        for inv <- m.invariants,
            not Regex.match?(~r/\b(val|def)\s+#{inv}\b/, text),
            do: "model: invariant #{inv} does not exist in model.qnt"
    end
  end

  @doc "A file's content from the overlay of files not yet written, or from the disk."
  def fetch(root, overlay, rel) do
    case overlay do
      %{^rel => content} -> {:ok, content}
      _ -> File.read(Path.join(root, rel))
    end
  end

  defp ignored(root, paths) do
    case Git.run(root, ["check-ignore", "--no-index", "--" | paths]) do
      {out, 0} -> String.split(out, "\n", trim: true)
      _ -> []
    end
  end

  # ---- Baseline and hash (VER-1, AUT-2) ----

  @doc "The acceptance baseline in card order: the Intent's files, its acceptance list, the config, protected files."
  def baseline(root, slug, %Config{} = config) do
    intent_files =
      Path.wildcard(Path.join([root, dir(slug), "**"]), match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.sort_by(&{&1 != intent_md(slug), &1 != feature(slug), &1})

    listed = if exists?(root, slug), do: read(root, slug).acceptance || [], else: []
    first = [intent_md(slug), feature(slug)] |> Enum.filter(&(&1 in intent_files))

    (first ++ listed ++ intent_files ++ [Config.path()] ++ protected(root, config))
    |> Enum.uniq()
  end

  @doc "Files matching `protect` (paths, folders or globs)."
  def protected(root, %Config{protect: patterns}) do
    files =
      root
      |> Git.ok!(["ls-files", "-z", "--cached", "--others", "--exclude-standard"])
      |> String.split("\0", trim: true)

    patterns
    |> Enum.flat_map(fn pat ->
      pat = String.trim_trailing(pat, "/")
      re = glob_regex(pat)
      Enum.filter(files, &(Regex.match?(re, &1) or String.starts_with?(&1, pat <> "/")))
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp glob_regex(pat) do
    body =
      pat
      |> String.split(~r/(\*\*\/|\*\*|\*|\?)/, include_captures: true)
      |> Enum.map_join(fn
        "**/" -> "(?:.*/)?"
        "**" -> ".*"
        "*" -> "[^/]*"
        "?" -> "[^/]"
        lit -> Regex.escape(lit)
      end)

    Regex.compile!("^" <> body <> "$")
  end

  @doc "SHA-256 over `<path>\\0<sha256 of bytes>\\n` for each baseline file, sorted by path."
  def hash(root, paths) do
    paths
    |> Enum.sort()
    |> Enum.map_join(fn p ->
      digest =
        case File.read(Path.join(root, p)) do
          {:ok, bytes} -> :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
          {:error, _} -> "missing"
        end

      p <> <<0>> <> digest <> "\n"
    end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # ---- Approval ----

  def approval_path(root, slug), do: Path.join(root, ".kogen/local/approvals/#{slug}.json")

  def approval(root, slug) do
    case File.read(approval_path(root, slug)) do
      {:ok, text} -> JSON.decode!(text)
      {:error, :enoent} -> nil
    end
  end
end
