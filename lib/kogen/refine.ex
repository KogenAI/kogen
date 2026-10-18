defmodule Kogen.Refine do
  @moduledoc "Targeted corrections to existing, unapproved ready drafts (SHP-11)."
  alias Kogen.{
    Bridge,
    Build,
    ChatGPT,
    Config,
    Error,
    Git,
    Intent,
    Lock,
    Readiness,
    Shape,
    Snapshot,
    Tools,
    Usage
  }

  def run(project, slug, expected, request) do
    root = Git.root!(project)
    lock = Build.lock!(root)

    try do
      config = Config.load!(root)
      Intent.exists!(root, slug)
      unapproved!(root, slug)

      if config.acceptance_run == nil or config.steps_dir == nil,
        do:
          Error.raise!(
            "environment",
            "acceptance_unconfigured",
            "set commands.acceptance in .kogen/project.yaml",
            3
          )

      original =
        case Intent.check(root, slug) do
          {:ok, intent, _} ->
            intent

          {_, problems} ->
            Error.raise!(
              "intent",
              "not_ready",
              "refinement requires an existing ready Intent",
              1,
              problems
            )
        end

      if File.exists?(Path.join(root, ".kogen/local/shaping/#{slug}/state.json")),
        do:
          constraint!(
            "Finish or discard the pending shaping questions before refining this draft."
          )

      unless is_binary(expected) and Regex.match?(~r/\A[0-9a-f]{64}\z/, expected),
        do:
          Error.raise!(
            "intent",
            "refinement_hash",
            "refinement requires the full 64-character baseline SHA-256",
            2
          )

      baseline = Intent.baseline(root, slug, config)
      if Intent.hash(root, baseline) != expected, do: stale!()

      head =
        Git.head(root) ||
          Error.raise!("environment", "no_head", "commit the project before refining", 3)

      tree = Snapshot.tree(root, head, [])
      ChatGPT.require_login!()
      Readiness.tools!(root, config)
      id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      evidence = Path.join(root, ".kogen/local/refinements/#{id}")
      scratch = Kogen.tmp_path("kogen-refine")

      files =
        Enum.filter(
          baseline,
          &(String.starts_with?(&1, Intent.dir(slug) <> "/") or
              &1 in original.acceptance)
        )

      originals = Map.new(files, &{&1, File.read!(Path.join(root, &1))})
      File.mkdir_p!(evidence)
      Bridge.progress("kogen: refinement evidence: #{evidence}")
      File.write!(Path.join(evidence, "request.md"), request)
      save_files(evidence, "original", originals)

      state = %{
        root: root,
        scratch: scratch,
        slug: slug,
        config: config,
        expected: expected,
        head: head,
        tree: tree,
        evidence: evidence,
        originals: originals,
        allowed: editable(root, slug, config, files)
      }

      try do
        Git.ok!(root, ["clone", "--quiet", "--shared", "--no-checkout", "--", root, scratch])
        Tools.copy_tree(root, scratch)
        Git.ok!(scratch, ["read-tree", tree])
        Readiness.check!(scratch, slug, config)

        if Snapshot.tree(scratch, head, []) != tree,
          do:
            constraint!(
              "Readiness changed project files; preserve the draft and resolve that before refining."
            )

        state = Map.put(state, :intent, original)
        role = config.models["shape"]
        input = [%{"role" => "user", "content" => context(state, request)}]
        tools = Tools.defs(~w(read_file list_files search_text probe)) ++ [submit_def()]
        {changes, usage} = converse(state, role, tools, input, 0, Usage.zero())
        freeze!(state)
        # Publication is serialized with approval/Build. Each destination existed at the
        # frozen baseline; scratch checks and failed submissions never write the draft.
        publish!(state, changes)
        result!(state, "ready", %{usage: usage, changed: Map.keys(changes)})

        Bridge.puts(
          "refined #{slug} #{String.slice(Intent.hash(root, Intent.baseline(root, slug, config)), 0, 8)}"
        )

        Bridge.puts("Changed: #{Enum.join(Map.keys(changes), ", ")}")
        Bridge.puts("Evidence: #{evidence}")
        Bridge.puts("Next: kogen intent approve #{slug}")
        0
      rescue
        e ->
          result!(state, "failed", %{error: Exception.message(e)})
          reraise e, __STACKTRACE__
      catch
        {:cancel, signal} ->
          result!(state, "interrupted", %{signal: signal})
          throw({:cancel, signal})
      after
        File.rm_rf(scratch)
      end
    after
      Lock.release(lock)
    end
  end

  defp unapproved!(root, slug) do
    if Intent.approval(root, slug),
      do:
        Error.raise!(
          "intent",
          "refinement_approved",
          "#{slug} already has an approval; refinement only corrects unapproved drafts. Preserve this package and use a new Intent for a changed request.",
          5
        )
  end

  defp publish!(s, changes) do
    save_files(s.evidence, "publish", changes)

    for {path, _} <- changes do
      File.chmod!(
        Path.join([s.evidence, "publish", path]),
        File.stat!(Path.join(s.root, path)).mode
      )
    end

    Bridge.check_cancel()
    freeze!(s)

    try do
      for {path, _} <- changes do
        unless regular_path?(s.root, path) and
                 File.read(Path.join(s.root, path)) == {:ok, Map.fetch!(s.originals, path)},
               do: stale!()

        File.rename!(Path.join([s.evidence, "publish", path]), Path.join(s.root, path))
        Bridge.check_cancel()
      end
    rescue
      error ->
        restore_published!(s, changes)
        reraise error, __STACKTRACE__
    catch
      {:cancel, signal} ->
        restore_published!(s, changes)
        throw({:cancel, signal})
    end
  end

  defp restore_published!(s, changes) do
    # Undo only our own completed replacements, never a subsequent external edit.
    for {path, content} <- changes,
        File.read(Path.join(s.root, path)) == {:ok, content},
        do: File.write!(Path.join(s.root, path), Map.fetch!(s.originals, path))
  end

  defp freeze!(s) do
    if Intent.approval(s.root, s.slug) != nil or Git.head(s.root) != s.head or
         Intent.hash(s.root, Intent.baseline(s.root, s.slug, s.config)) != s.expected or
         Snapshot.tree(s.root, s.head, []) != s.tree,
       do: stale!()
  end

  defp stale!,
    do:
      Error.raise!(
        "intent",
        "refinement_stale",
        "the draft or checkout changed; nothing was replaced. Review its current full hash and retry.",
        1
      )

  defp constraint!(reason),
    do:
      Error.raise!(
        "shape",
        "refinement_constraint",
        reason <> " The original draft is preserved.",
        1
      )

  defp editable(root, slug, config, files) do
    shared =
      Path.wildcard(Path.join(root, ".kogen/intents/*/intent.md"))
      |> Enum.reject(&(&1 == Path.join(root, Intent.intent_md(slug))))
      |> Enum.flat_map(fn path ->
        other = path |> Path.dirname() |> Path.basename()
        Intent.read(root, other).acceptance || []
      end)

    protected = Intent.protected(root, config)

    Enum.filter(files, fn path ->
      own =
        path in Enum.map(
          ~w(intent.md acceptance.feature model.qnt),
          &(Intent.dir(slug) <> "/" <> &1)
        )

      step =
        config.steps_dir != nil and String.starts_with?(path, config.steps_dir <> "/") and
          path not in shared and Git.show(root, "HEAD", path) == nil

      (own or step) and path not in protected and regular_path?(root, path)
    end)
  end

  # Existing paths must be ordinary files with no symlink ancestor; publishing a
  # correction must not follow a link into another artifact or outside the checkout.
  defp regular_path?(root, path) do
    path
    |> Path.split()
    |> Enum.scan(root, &Path.join(&2, &1))
    |> Enum.all?(fn full ->
      case File.lstat(full) do
        {:ok, %{type: type}} -> type in [:regular, :directory]
        _ -> false
      end
    end)
  end

  defp converse(s, role, tools, input, invalid, usage) do
    Bridge.check_cancel()
    freeze!(s)
    Bridge.progress("kogen: refining #{s.slug} #{role.model}/#{role.effort}")
    started = System.monotonic_time(:millisecond)
    response = ChatGPT.respond(role, instructions(), input, tools)

    Bridge.progress(
      "kogen: refinement response #{Usage.line(response.usage)} wall_ms=#{System.monotonic_time(:millisecond) - started}"
    )

    usage = Usage.add(usage, response.usage)
    replay = Enum.map(response.items, &Shape.replay_item/1) |> Enum.reject(&is_nil/1)
    calls = for %{"type" => "function_call"} = call <- response.items, do: call
    ctx = %{root: s.scratch, protected: [], tools: ~w(read_file list_files search_text probe)}

    {outputs, outcome} =
      Enum.reduce(calls, {[], nil}, fn call, {outputs, outcome} ->
        Bridge.check_cancel()

        {text, next} =
          cond do
            outcome != nil -> {"ignored: only one submission counts", outcome}
            call["name"] == "submit_refinement" -> submit(s, Shape.decode(call))
            true -> {Tools.run(call["name"], Shape.decode(call), ctx) |> Tools.cut(), nil}
          end

        {outputs ++ [Shape.output(call, text)], next}
      end)

    input = input ++ replay ++ outputs

    case outcome do
      {:ready, files} ->
        {files, usage}

      {:constraint, reason} ->
        constraint!(reason)

      _ ->
        invalid = if outcome == nil and calls != [], do: invalid, else: invalid + 1

        if invalid >= 3,
          do:
            Error.raise!(
              "shape",
              "refinement_invalid",
              "no valid ready correction after 3 submissions; the original draft is preserved",
              1,
              case outcome do
                {:invalid, diagnostic} -> String.split(diagnostic, "\n")
                _ -> []
              end
            )

        input =
          if calls == [],
            do:
              input ++
                [
                  %{
                    "role" => "user",
                    "content" =>
                      "Call submit_refinement with changed existing files, or constraint."
                  }
                ],
            else: input

        converse(s, role, tools, input, invalid, usage)
    end
  end

  defp submit(_s, %{"constraint" => reason} = args)
       when map_size(args) == 1 and is_binary(reason) do
    if String.trim(reason) != "",
      do: {"constraint recorded", {:constraint, reason}},
      else:
        {"invalid: constraint must explain the unsupported work",
         {:invalid, "constraint must explain the unsupported work"}}
  end

  defp submit(s, %{"files" => [_ | _] = files} = args) when map_size(args) == 1 do
    attempt = System.unique_integer([:positive])
    File.write!(Path.join(s.evidence, "submission-#{attempt}.json"), JSON.encode!(args))
    paths = for %{"path" => path} <- files, do: path

    valid =
      Enum.all?(files, fn
        %{"path" => path, "content" => content} = file ->
          map_size(file) == 2 and path in s.allowed and is_binary(content)

        _ ->
          false
      end) and length(paths) == length(Enum.uniq(paths))

    if not valid do
      diagnostic =
        "invalid: a path is not an exclusively owned editable draft file, or a change has invalid content/duplicate paths; no new/shared/protected paths"

      File.write!(Path.join(s.evidence, "diagnostic-#{attempt}.txt"), diagnostic)
      {diagnostic, {:invalid, diagnostic}}
    else
      Git.ok!(s.scratch, ["read-tree", "--reset", "-u", s.tree])
      changes = Map.new(files, &{&1["path"], &1["content"]})
      for {path, content} <- changes, do: File.write!(Path.join(s.scratch, path), content)
      save_files(s.evidence, "candidate-#{attempt}", changes)

      try do
        for command <- s.config.fix do
          result = Bridge.exec(command, s.scratch)
          if result.status != 0, do: constraint!("A configured fixer failed: #{command}")
        end

        candidate = Intent.read(s.scratch, s.slug)

        if candidate.acceptance != s.intent.acceptance or
             model_path(candidate) != model_path(s.intent),
           do:
             constraint!(
               "Refinement cannot add/remove Acceptance paths or change whether a model exists; it changes existing files only."
             )

        tree = Snapshot.tree(s.scratch, s.head, [])

        if Enum.any?(Snapshot.changed(s.scratch, s.tree, tree), &(&1 not in paths)),
          do: constraint!("A fixer changed files outside the submitted correction.")

        Readiness.check!(s.scratch, s.slug, s.config)

        if Snapshot.tree(s.scratch, s.head, []) != tree,
          do:
            constraint!(
              "Readiness changed candidate files; a stable ready correction is required."
            )

        changes = Map.new(paths, &{&1, File.read!(Path.join(s.scratch, &1))})
        save_files(s.evidence, "candidate-#{attempt}", changes)
        {"accepted: merged draft is ready", {:ready, changes}}
      rescue
        e in Error ->
          diagnostic = Error.render(e)
          File.write!(Path.join(s.evidence, "diagnostic-#{attempt}.txt"), diagnostic)

          if e.reason == "refinement_constraint",
            do: {diagnostic, {:constraint, e.detail}},
            else: {"not ready:\n" <> diagnostic, {:invalid, diagnostic}}
      end
    end
  end

  defp submit(_s, _args) do
    diagnostic =
      "invalid: submit exactly files (changed existing files only) or constraint (why this correction needs unsupported work)"

    {diagnostic, {:invalid, diagnostic}}
  end

  defp model_path(intent) do
    case Intent.model(intent) do
      %{path: path} -> path
      value -> value
    end
  end

  defp save_files(evidence, folder, files) do
    for {path, content} <- files do
      destination = Path.join([evidence, folder, path])
      File.mkdir_p!(Path.dirname(destination))
      File.write!(destination, content)
    end
  end

  defp result!(s, outcome, extra),
    do:
      File.write!(
        Path.join(s.evidence, "result.json"),
        JSON.encode!(
          Map.merge(%{outcome: outcome, slug: s.slug, baseline: s.expected, head: s.head}, extra)
        ) <> "\n"
      )

  defp context(s, request) do
    """
    # Correction requested
    #{request}
    # Existing ready package (full contents; omitted files stay byte-identical)
    #{Enum.map_join(s.originals, "\n", fn {path, content} -> "--- #{path}\n#{content}" end)}
    # Exclusively owned editable files
    #{Enum.join(s.allowed, "\n")}
    # Protection and commands
    Configured protected files: #{inspect(Intent.protected(s.root, s.config))}
    No config, protected, shared or other Intent files may change. Existing Acceptance paths and model presence/path must remain unchanged.
    Fixers: #{inspect(s.config.fix)}
    Acceptance: #{s.config.acceptance_run}
    # Project README
    #{Shape.readme(s.root)}
    # Testing rules
    #{Kogen.testing_rules()}
    """
  end

  defp instructions do
    "Correct only the requested points in an existing ready, unapproved Intent. Read/probe as needed. Reuse all unchanged artifacts: submit_refinement contains only complete replacement contents of changed existing editable files, never the whole package. Preserve its required Intent sections, executable scenarios, meaningful tests and model. Do not implement product code, authorize, approve or build. No new/deleted files, shared step edits, Acceptance path changes, model removal/addition, or UI/UX question/resume flow is supported. If the requested correction requires any of these or a protected edit, submit only constraint with a concrete reason; never silently reinterpret or discard the draft. Kogen formats the submitted files and checks the complete merged package in a scratch checkout. Readiness failures return for correction; the original package stays unchanged unless the full candidate is ready and its frozen hash/HEAD still match. End with submit_refinement."
  end

  defp submit_def do
    %{
      "type" => "function",
      "name" => "submit_refinement",
      "strict" => false,
      "description" =>
        "Submit only changed existing draft files, or an explicit unsupported-work constraint.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "files" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "path" => %{"type" => "string"},
                "content" => %{"type" => "string"}
              },
              "required" => ["path", "content"]
            }
          },
          "constraint" => %{"type" => "string"}
        }
      }
    }
  end
end
