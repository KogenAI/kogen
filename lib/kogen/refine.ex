defmodule Kogen.Refine do
  @moduledoc "Targeted corrections to existing ready packages, requiring fresh approval (SHP-11)."
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
      approval = approval_bytes(root, slug)

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

      if approval != nil do
        unless match?({:ok, %{"sha256" => ^expected}}, JSON.decode(approval)), do: stale!()
        Build.clean_paths!(root, slug)
      end

      head =
        Git.head(root) ||
          Error.raise!("environment", "no_head", "commit the project before refining", 3)

      tree = Snapshot.tree(root, head, [])

      index_path =
        Git.ok!(root, ["rev-parse", "--path-format=absolute", "--git-path", "index"])
        |> String.trim()

      index = index_digest(index_path)
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
      Kogen.ShapeEvidence.start(evidence, slug)
      Bridge.progress("kogen: refinement evidence: #{evidence}")
      File.write!(Path.join(evidence, "request.md"), request)
      if approval, do: File.write!(Path.join(evidence, "original-approval.json"), approval)
      save_files(evidence, "original", originals)

      state = %{
        root: root,
        scratch: scratch,
        slug: slug,
        config: config,
        expected: expected,
        head: head,
        tree: tree,
        approval: approval,
        index_path: index_path,
        index: index,
        evidence: evidence,
        originals: originals,
        proposed: %{},
        observed: nil,
        allowed: editable(root, slug, config, files)
      }

      try do
        Git.ok!(root, ["clone", "--quiet", "--shared", "--no-checkout", "--", root, scratch])
        Tools.copy_tree(root, scratch)
        # The warm preparation clone has its own Git metadata. Keep the source's
        # ignore rules here so local workspace warmth cannot become candidate
        # inputs merely because clone did not copy info/exclude or local config.
        # Final proof still materializes only the Snapshot, never this metadata.
        exclude =
          root
          |> Git.ok!(["rev-parse", "--path-format=absolute", "--git-path", "info/exclude"])
          |> String.trim()

        if File.regular?(exclude), do: File.cp!(exclude, Path.join(scratch, ".git/info/exclude"))

        case Git.run(root, ["config", "--path", "--get", "core.excludesFile"]) do
          {path, 0} ->
            Git.ok!(scratch, ["config", "core.excludesFile", Path.expand(String.trim(path), root)])

          {_, 1} ->
            :ok
        end

        Git.ok!(scratch, ["read-tree", tree])
        freeze!(state)
        cached = Readiness.cached(root, slug, config)

        if cached do
          File.cp!(
            Path.join(root, ".kogen/local/readiness/#{slug}.json"),
            Path.join(evidence, "retained-original-readiness.json")
          )
        end

        before_counts =
          Map.new(~w(setup acceptance quint), &{&1, Kogen.ShapeEvidence.count_value(&1)})

        original_ready =
          try do
            cached ||
              Kogen.ShapeEvidence.timed("readiness", fn ->
                Readiness.check!(scratch, slug, config)
              end)
          after
            counts =
              Map.new(before_counts, fn {k, n} -> {k, Kogen.ShapeEvidence.count_value(k) - n} end)

            File.write!(
              Path.join(evidence, "original-readiness.json"),
              JSON.encode!(%{
                event: "original_readiness",
                status: if(cached, do: "hit", else: "miss"),
                reason:
                  if(cached,
                    do: "valid complete version3 protected-baseline/HEAD evidence",
                    else: "no valid complete version3 evidence; normal scratch path"
                  ),
                source: if(cached, do: "retained", else: "scratch"),
                baseline: expected,
                head: head,
                reference:
                  if(cached,
                    do: "retained-original-readiness.json",
                    else: "original-observations.txt"
                  ),
                setup_executions: counts["setup"],
                acceptance_executions: counts["acceptance"],
                model_executions: counts["quint"],
                avoided: %{setup: nil, acceptance: nil, model: nil, source_wall_ms: nil}
              })
            )
          end

        if Snapshot.tree(scratch, head, []) != tree,
          do:
            constraint!(
              "Readiness changed project files; preserve the draft and resolve that before refining."
            )

        File.write!(
          Path.join(evidence, "original-readiness-observations.json"),
          JSON.encode!(Map.drop(original_ready, [:intent]))
        )

        original_reference = Path.join(evidence, "original-observations.txt")
        original_observations = Readiness.observations(slug, original_ready, original_reference)
        if original_observations != "", do: File.write!(original_reference, original_observations)

        state =
          state
          |> Map.put(:intent, original)
          |> Map.put(:original_observations, original_observations)
          |> Map.put(:observed, if(Readiness.failures?(original_ready), do: original_ready))

        role = config.models["shape"]
        input = [%{"role" => "user", "content" => context(state, request)}]
        tools = Tools.defs(~w(read_file list_files search_text probe)) ++ [submit_def()]
        {changes, ready, usage} = converse(state, role, tools, input, 0, Usage.zero())
        freeze!(state)
        # Publication is serialized with approval/Build. Each destination existed at the
        # frozen baseline; scratch checks and failed submissions never write the draft.
        publish!(state, changes, ready)
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
          extra = %{error: Exception.message(e)}

          extra =
            case e do
              %Error{provider_failure: diagnostics} when is_map(diagnostics) ->
                Map.put(extra, :provider_failure, diagnostics)

              _ ->
                extra
            end

          result!(state, "failed", extra)
          reraise e, __STACKTRACE__
      catch
        {:cancel, signal} ->
          result!(state, "interrupted", %{signal: signal})
          throw({:cancel, signal})
      after
        Kogen.ShapeEvidence.finish()
        File.rm_rf(scratch)
      end
    after
      Lock.release(lock)
    end
  end

  defp approval_bytes(root, slug) do
    case File.read(Intent.approval_path(root, slug)) do
      {:ok, bytes} ->
        bytes

      {:error, :enoent} ->
        nil

      {:error, reason} ->
        raise File.Error,
          reason: reason,
          action: "read approval",
          path: Intent.approval_path(root, slug)
    end
  end

  defp index_digest(path) do
    case File.read(path) do
      {:ok, bytes} -> :crypto.hash(:sha256, bytes)
      {:error, :enoent} -> nil
      {:error, reason} -> raise File.Error, reason: reason, action: "read index", path: path
    end
  end

  defp publish!(s, changes, ready) do
    save_files(s.evidence, "publish", changes)
    save_files(s.evidence, "rollback", Map.take(s.originals, Map.keys(changes)))

    for {path, _} <- changes do
      mode = File.stat!(Path.join(s.root, path)).mode
      File.chmod!(Path.join([s.evidence, "publish", path]), mode)
      File.chmod!(Path.join([s.evidence, "rollback", path]), mode)
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

      if s.approval do
        if approval_bytes(s.root, s.slug) != s.approval or
             index_digest(s.index_path) != s.index or Git.head(s.root) != s.head,
           do: stale!()

        File.rename!(
          Intent.approval_path(s.root, s.slug),
          Path.join(s.evidence, "revoked-approval.json")
        )

        Bridge.check_cancel()
      end

      Readiness.record_pass!(s.root, s.slug, s.config, ready)
    rescue
      error ->
        restore_published!(s, changes)
        restore_approval!(s)
        reraise error, __STACKTRACE__
    catch
      {:cancel, signal} ->
        restore_published!(s, changes)
        restore_approval!(s)
        throw({:cancel, signal})
    end
  end

  defp restore_approval!(%{approval: nil}), do: :ok

  defp restore_approval!(s) do
    archived = Path.join(s.evidence, "revoked-approval.json")

    if approval_bytes(s.root, s.slug) == nil and File.read(archived) == {:ok, s.approval},
      do: File.rename!(archived, Intent.approval_path(s.root, s.slug))
  end

  defp restore_published!(s, changes) do
    # Undo only our own completed replacements, never a subsequent external edit.
    for {path, content} <- changes,
        regular_path?(s.root, path),
        File.read(Path.join(s.root, path)) == {:ok, content},
        do: File.rename!(Path.join([s.evidence, "rollback", path]), Path.join(s.root, path))
  end

  defp freeze!(s) do
    if approval_bytes(s.root, s.slug) != s.approval or index_digest(s.index_path) != s.index or
         Git.head(s.root) != s.head or
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

    manifest =
      Enum.map(Enum.sort(s.originals), fn {p, c} ->
        %{
          path: p,
          revision: %{head: s.head, tree: s.tree},
          sha256: Kogen.ShapeContext.hash(c),
          source: Path.join([s.evidence, "original", p]),
          proposed:
            if(Map.has_key?(s.proposed, p),
              do: %{
                sha256: Kogen.ShapeContext.hash(File.read!(Path.join(s.scratch, p))),
                source: Path.join(s.scratch, p),
                submitted_sha256: Kogen.ShapeContext.hash(s.proposed[p])
              },
              else: nil
            )
        }
      end)

    input =
      input ++
        [
          %{
            "role" => "user",
            "content" => "Cumulative proposal/original manifest: " <> JSON.encode!(manifest)
          }
        ]

    Kogen.ShapeContext.measure(input, manifest)

    response =
      Kogen.ShapeEvidence.provider(
        "shape",
        nil,
        %{head: s.head, tree: s.tree},
        "targeted refinement",
        role,
        fn ->
          ChatGPT.respond(role, instructions() <> Kogen.ShapeContext.guidance(), input, tools)
        end
      )

    Bridge.progress(
      "kogen: refinement response #{Usage.line(response.usage)} wall_ms=#{System.monotonic_time(:millisecond) - started}"
    )

    usage = Usage.add(usage, response.usage)
    replay = Enum.map(response.items, &Shape.replay_item/1) |> Enum.reject(&is_nil/1)
    calls = for %{"type" => "function_call"} = call <- response.items, do: call
    ctx = %{root: s.scratch, protected: [], tools: ~w(read_file list_files search_text probe)}

    {outputs, outcome, s} =
      Enum.reduce(calls, {[], nil, s}, fn call, {outputs, outcome, s} ->
        Bridge.check_cancel()

        {text, next, s} =
          cond do
            outcome != nil ->
              {"ignored: only one submission counts", outcome, s}

            call["name"] == "submit_refinement" ->
              submit(s, Shape.decode(call))

            true ->
              text =
                if call["name"] == "probe",
                  do:
                    Kogen.ShapeEvidence.probe(fn ->
                      Tools.run(call["name"], Shape.decode(call), ctx)
                    end),
                  else: Tools.run(call["name"], Shape.decode(call), ctx)

              {text, nil, s}
          end

        {outputs ++ [Shape.output(call, text)], next, s}
      end)

    input = input ++ replay ++ outputs

    case outcome do
      {:ready, files, ready} ->
        {files, ready, usage}

      :observations ->
        converse(s, role, tools, input, invalid, usage)

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
                      "Call submit_refinement with a nonempty files array of complete existing owned artifact contents (edits or readiness acknowledgment), or constraint."
                  }
                ],
            else: input

        converse(s, role, tools, input, invalid, usage)
    end
  end

  defp submit(s, %{"constraint" => reason} = args)
       when map_size(args) == 1 and is_binary(reason) do
    if String.trim(reason) != "",
      do: {"constraint recorded", {:constraint, reason}, s},
      else:
        {"invalid: constraint must explain the unsupported work",
         {:invalid, "constraint must explain the unsupported work"}, s}
  end

  defp submit(s, %{"files" => [_ | _] = files} = args) when map_size(args) == 1 do
    attempt = System.unique_integer([:positive])
    File.write!(Path.join(s.evidence, "submission-#{attempt}.json"), JSON.encode!(args))
    paths = for %{"path" => path} <- files, do: path

    valid =
      Enum.all?(files, fn
        %{"path" => path, "content" => content} = file ->
          map_size(file) == 2 and is_binary(path) and path in s.allowed and is_binary(content)

        _ ->
          false
      end) and length(paths) == length(Enum.uniq(paths))

    if not valid do
      diagnostic =
        "invalid: a path is not an exclusively owned editable draft file, or a change has invalid content/duplicate paths; no new/shared/protected paths. No proposals from this submission were retained; earlier proposals are unchanged."

      File.write!(Path.join(s.evidence, "diagnostic-#{attempt}.txt"), diagnostic)
      {diagnostic, {:invalid, diagnostic}, s}
    else
      s = %{s | proposed: Map.merge(s.proposed, Map.new(files, &{&1["path"], &1["content"]}))}
      paths = Map.keys(s.proposed)
      Git.ok!(s.scratch, ["read-tree", "--reset", "-u", s.tree])
      changes = s.proposed
      for {path, content} <- changes, do: File.write!(Path.join(s.scratch, path), content)
      save_files(s.evidence, "candidate-#{attempt}", changes)

      try do
        for command <- s.config.fix do
          result = Bridge.exec(command, s.scratch)
          if result.status != 0, do: constraint!("A configured fixer failed: #{command}")
        end

        candidate = Intent.read(s.scratch, s.slug)
        candidate_model = model_path(candidate)

        if candidate.acceptance != s.intent.acceptance or
             (candidate_model != nil and candidate_model != model_path(s.intent)),
           do:
             constraint!(
               "Refinement cannot add/remove Acceptance paths or change whether a model exists; it changes existing files only."
             )

        # Unparseable Model metadata is a correctable lint failure, not proof of
        # model removal. Readiness rejects it before any candidate can publish.

        tree = Snapshot.tree(s.scratch, s.head, [])

        if Enum.any?(Snapshot.changed(s.scratch, s.tree, tree), &(&1 not in paths)),
          do: constraint!("A fixer changed files outside the submitted correction.")

        acknowledged = Readiness.current?(s.scratch, s.slug, s.config, s.observed)

        ready =
          if acknowledged do
            s.observed
          else
            Kogen.ShapeEvidence.timed("readiness", fn ->
              Readiness.check!(s.scratch, s.slug, s.config)
            end)
          end

        if Snapshot.tree(s.scratch, s.head, []) != tree,
          do:
            constraint!(
              "Readiness changed candidate files; a stable ready correction is required."
            )

        changes = Map.new(paths, &{&1, File.read!(Path.join(s.scratch, &1))})
        save_files(s.evidence, "candidate-#{attempt}", changes)

        if not acknowledged and Readiness.failures?(ready) do
          reference = Path.join(s.evidence, "observations-#{attempt}.txt")
          File.write!(reference, Readiness.observations(s.slug, ready, reference))

          {Readiness.acknowledgment(s.slug, ready, reference), :observations,
           %{s | observed: ready}}
        else
          {"accepted: complete accumulated draft is ready", {:ready, changes, ready}, s}
        end
      rescue
        e in Error ->
          diagnostic = Error.render(e)
          File.write!(Path.join(s.evidence, "diagnostic-#{attempt}.txt"), diagnostic)

          if e.reason == "refinement_constraint",
            do: {diagnostic, {:constraint, e.detail}, s},
            else:
              {"not ready:\n" <>
                 diagnostic <>
                 "\nWell-formed proposals are retained in this run; submit only corrections. Omitted paths retain their previous proposal, or the original if never proposed.",
               {:invalid, diagnostic}, s}
      end
    end
  end

  defp submit(s, _args) do
    diagnostic =
      "invalid: submit exactly a nonempty files array of complete existing owned artifact contents (edits or readiness acknowledgment), or constraint (why this correction needs unsupported work). No proposals from this submission were retained; earlier proposals are unchanged."

    {diagnostic, {:invalid, diagnostic}, s}
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
    {selected, _} =
      Kogen.ShapeContext.index(s.root, s.slug, s.config, request, s.originals,
        owned: s.allowed,
        original_dir: Path.join(s.evidence, "original"),
        full_paths: [
          "README.md"
          | Enum.filter(
              Map.keys(s.originals),
              &String.ends_with?(&1, ["intent.md", "acceptance.feature", "model.qnt"])
            )
        ]
      )

    """
    Full contract inclusions: original Intent prose, Gherkin and declared model preserve exact authority, irrespective of excerpt budget.

    # Correction requested
    #{request}
    # Original authoritative contracts and owned originals (full contents)
    Within this run, omitted paths retain earlier well-formed proposals; paths never proposed retain these original bytes. Submit original content explicitly to revert a proposal. Nothing is published until the complete accumulated candidate is ready.
    #{Enum.map_join(Enum.sort(s.originals), "\n", fn {path, content} -> "--- #{path}\n#{content}" end)}
    # Exclusively owned editable files
    #{Enum.join(s.allowed, "\n")}
    # Protection and commands
    Configured protected files: #{inspect(Intent.protected(s.root, s.config))}
    No config, protected, shared or other Intent files may change. Existing Acceptance paths and model presence/path must remain unchanged.
    Setup: #{inspect(s.config.setup)}
    Checks: #{inspect(s.config.checks)}
    Fixers: #{inspect(s.config.fix)}
    Acceptance: #{s.config.acceptance_run}
    # Project README
    #{Shape.readme(s.root)}
    # Testing rules
    #{Kogen.testing_rules()}
    """
    |> Kogen.PromptCache.contract_blocks("""
    # Original baseline observations
    Exact retained readiness result: #{Path.join(s.evidence, "original-readiness-observations.json")}
    #{s.original_observations}
    #{selected}
    """)
  end

  defp instructions do
    "#{Kogen.Feasibility.guidance()} Correct only the requested points in an existing ready Intent. Read/probe as needed. For edits, submit_refinement contains complete replacement contents of changed existing editable files; omit unchanged artifacts. Well-formed proposals accumulate within this run: latest content for a path wins, omitted paths retain earlier proposed bytes, and explicit original content reverts a proposal. A malformed or unsafe submission contributes no paths. Each retry checks the complete accumulated candidate against the frozen original; nothing is published until all of it is ready. Accounted red observations return for inspection in this same conversation: repair demonstrated contract defects using existing read/probe tools as needed. #{Readiness.acknowledgment_guidance()} Failures can mask later cases; do not claim all fixtures are correct. Preserve its required Intent sections, executable scenarios, meaningful tests and model. Do not implement product code, authorize, approve or build. No new/deleted files, shared step edits, Acceptance path changes, model removal/addition, or UI/UX question/resume flow is supported. If the requested correction requires any of these or a protected edit, submit only constraint with a concrete reason; never silently reinterpret or discard the draft. Kogen formats the submitted files and checks the complete merged package in a scratch checkout. Readiness failures return for correction; the original package and approval stay unchanged unless the full candidate is ready and its frozen hash/HEAD/tree/index/approval still match. Successful correction revokes any old approval; the caller must explicitly approve the resulting full hash. End with submit_refinement."
  end

  defp submit_def do
    %{
      "type" => "function",
      "name" => "submit_refinement",
      "strict" => false,
      "description" =>
        "For edits, submit changed existing files; well-formed proposals accumulate in this run and omitted paths retain earlier proposed bytes. Submit original content only to intentionally revert an edit. #{Readiness.acknowledgment_guidance()} Or report an explicit unsupported-work constraint.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "files" => %{
            "type" => "array",
            "minItems" => 1,
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
