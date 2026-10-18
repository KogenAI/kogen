defmodule Kogen.Init do
  @moduledoc """
  `kogen init` (SET-1..5, SET-10..13): detect the project's commands, ask the shaping model once,
  keep what passes on a copy of the committed tree, add the Cucumber bridge when there is no
  runner, and commit the configuration.
  """
  alias Kogen.{Bridge, ChatGPT, Config, Detect, Error, Git, Readiness, Shape, Tools, Usage}

  @ignore ".kogen/local/"
  @steps_readme_path "features/steps/README.md"
  @steps_readme "Cucumber step definitions for Kogen acceptance scenarios.\n"
  @instruction_files ~w(AGENTS.md CLAUDE.md GEMINI.md .cursorrules .cursor/rules .github/copilot-instructions.md)
  @sources ~w(README.md mix.exs package.json Makefile .tool-versions .gitlab-ci.yml)
  @next_acceptance "Next: set commands.acceptance in .kogen/project.yaml"
  @next_checks "Next: add the project's checks to commands.checks in .kogen/project.yaml"

  def run(dir) do
    root = Git.root!(dir)
    Git.identity!(root)
    head = Git.head(root)

    if File.exists?(Path.join(root, Config.path())), do: Config.load!(root)

    if head && Git.show(root, head, Config.path()) do
      config = Config.load!(root)
      Bridge.puts("Kogen is already initialized in #{root}")
      next_lines(config)
    else
      paths = [Config.path(), ".gitignore", @steps_readme_path]
      dirty = Git.changed_paths(root, paths)
      uncommitted = if head, do: [], else: Git.changed_paths(root) -- [".gitignore"]

      cond do
        Config.path() in dirty and File.regular?(Path.join(root, Config.path())) ->
          commit_leftover(root, head, dirty)

        path = head && Enum.find(paths, &(&1 in dirty)) ->
          Error.raise!(
            "environment",
            "dirty_tree",
            "#{path} has uncommitted changes; commit, stash or discard them first",
            5
          )

        head == nil and uncommitted != [] ->
          Error.raise!(
            "environment",
            "no_commits",
            "#{length(uncommitted)} file(s) are not committed yet; commit them first (git add -A && git commit -m \"Initial commit\"), then run kogen init",
            3
          )

        head == nil ->
          write_files(root, nil, Config.template(), %{})
          sha = commit!(root, [Config.path(), ".gitignore"], nil)
          Bridge.puts("Initialized Kogen in #{root}")
          Bridge.puts("Commit: #{sha} Initial commit (the first commit of this repository)")
          Bridge.puts(@next_acceptance)
          Bridge.puts(@next_checks)

        true ->
          configure(root, head)
      end
    end

    0
  end

  # SET-3: a configuration a failed init commit left behind is committed as it is.
  defp commit_leftover(root, head, dirty) do
    Config.load!(root)
    gitignore = Path.join(root, ".gitignore")
    File.write!(gitignore, with_line(read(gitignore), @ignore))
    paths = [Config.path(), ".gitignore"] ++ Enum.filter([@steps_readme_path], &(&1 in dirty))
    sha = commit!(root, paths, head)
    Bridge.puts("Initialized Kogen in #{root}")
    Bridge.puts("Commit: #{sha} Add Kogen configuration")
    next_lines(Config.load!(root))
  end

  defp configure(root, head) do
    ChatGPT.require_login!()
    Bridge.progress("kogen: detecting the project's commands")

    tracked =
      root |> Git.ok!(["ls-tree", "-r", "--name-only", "HEAD"]) |> String.split("\n", trim: true)

    detected =
      Detect.detect(Map.new(~w(mix.exs package.json), &{&1, Git.show(root, head, &1)}), tracked)

    proposed = ask(root, head, detected, tracked)
    clone = Kogen.tmp_path("kogen-init")

    result =
      try do
        committed_copy!(root, clone, tracked)
        verify(root, clone, merge(detected, proposed), detected.runner)
      after
        File.rm_rf(clone)
      end

    write_files(root, head, Config.render(result), result.files)
    Bridge.puts("Initialized Kogen in #{root}")

    Bridge.puts(
      "Setup: " <> if(result.setup == [], do: "none", else: Enum.join(result.setup, "; "))
    )

    Bridge.puts(
      "Checks: " <>
        cond do
          result.checks != [] -> Enum.map_join(result.checks, ", ", & &1.name)
          result.left_out == [] -> "none found"
          true -> "none passed"
        end
    )

    if result.left_out != [], do: Bridge.puts("Left out: " <> Enum.join(result.left_out, "; "))
    Bridge.puts("Acceptance: " <> result.how)

    case Enum.filter(@instruction_files, fn f ->
           Enum.any?(tracked, &(&1 == f or String.starts_with?(&1, f <> "/")))
         end) do
      [] ->
        :ok

      found ->
        Bridge.puts(
          "Note: Kogen gives its models README.md only; it does not read #{Enum.join(found, ", ")}"
        )
    end

    paths = [Config.path(), ".gitignore"] ++ if(result.bridge, do: [@steps_readme_path], else: [])
    Bridge.puts("Commit: #{commit!(root, paths, head)} Add Kogen configuration")
    next_lines(Config.load!(root))
  end

  # ---- SET-11: one request to the shaping model ----

  defp ask(root, head, detected, tracked) do
    role = Config.default_models()["shape"]
    Bridge.progress("kogen: asking #{role.model}/#{role.effort} about the project's commands")
    t0 = System.monotonic_time(:millisecond)

    ci =
      Enum.filter(tracked, &Regex.match?(~r{^\.github/workflows/[^/]+\.ya?ml$}, &1))

    sources =
      for path <- @sources ++ ci, path in tracked, text = Git.show(root, head, path), into: "" do
        "\n## File #{path}\n\n```\n#{Tools.cut(text)}\n```\n"
      end

    input = [
      %{
        "role" => "user",
        "content" =>
          "# Detected\n\n" <>
            JSON.encode!(Map.take(detected, [:setup, :fix, :checks, :protect])) <>
            "\n\n# Tracked files\n\n" <> Tools.cut(Enum.join(tracked, "\n")) <> "\n" <> sources
      }
    ]

    {proposal, usage} = converse(role, input, tracked, 1, Usage.zero())

    Bridge.progress(
      "kogen: init #{role.model}/#{role.effort} " <>
        Usage.line(usage) <> " wall_ms=#{System.monotonic_time(:millisecond) - t0}"
    )

    proposal
  end

  defp converse(role, input, tracked, attempt, usage) do
    resp = ChatGPT.respond(role, instructions(), input, [submit_def()])
    usage = Usage.add(usage, resp.usage)

    call =
      Enum.find(
        resp.items,
        &(&1["type"] == "function_call" and &1["name"] == "submit_configuration")
      )

    replay = resp.items |> Enum.map(&Shape.replay_item/1) |> Enum.reject(&is_nil/1)

    case call && validate(Shape.decode(call), tracked) do
      {:ok, proposal} ->
        {proposal, usage}

      _ when attempt == 2 ->
        Error.raise!(
          "provider",
          "init_invalid",
          "the model did not return a valid configuration; nothing was written",
          4
        )

      nil ->
        more = [%{"role" => "user", "content" => "Answer by calling submit_configuration."}]
        converse(role, input ++ replay ++ more, tracked, 2, usage)

      {:invalid, problems} ->
        more = [Shape.output(call, "invalid: " <> Enum.join(problems, "; "))]
        converse(role, input ++ replay ++ more, tracked, 2, usage)
    end
  end

  @doc "Validates a `submit_configuration` call's arguments (SET-11)."
  def validate(args, tracked) do
    strings = fn key ->
      case Map.get(args, key, []) do
        list when is_list(list) ->
          if Enum.all?(list, &(is_binary(&1) and String.trim(&1) != "")),
            do: {list, []},
            else: {[], ["#{key} must be a list of non-empty commands"]}

        _ ->
          {[], ["#{key} must be a list"]}
      end
    end

    {setup, p1} = strings.("setup")
    {fix, p2} = strings.("fix")
    {protect, p3} = strings.("protect")

    p4 =
      for path <- protect, path not in tracked, do: "protect path #{path} is not a tracked file"

    {checks, p5} = checks(Map.get(args, "checks", []))

    case p1 ++ p2 ++ p3 ++ p4 ++ p5 do
      [] -> {:ok, %{setup: setup, fix: fix, checks: checks, protect: protect}}
      problems -> {:invalid, problems}
    end
  end

  defp checks(list) when is_list(list) do
    {checks, problems} =
      Enum.reduce(list, {[], []}, fn
        %{"name" => name, "run" => run}, {acc, probs} when is_binary(name) and is_binary(run) ->
          cond do
            name in ~w(acceptance model) ->
              {acc, probs ++ ["check name #{name} is reserved"]}

            not Regex.match?(~r/^[a-z0-9]+(-[a-z0-9]+)*$/, name) ->
              {acc, probs ++ ["check name #{name} must be lowercase letters, digits and dashes"]}

            Enum.any?(acc, &(&1.name == name)) ->
              {acc, probs ++ ["check name #{name} is used twice"]}

            String.trim(run) == "" ->
              {acc, probs ++ ["check #{name} has no command"]}

            true ->
              {acc ++ [%{name: name, run: run}], probs}
          end

        _, {acc, probs} ->
          {acc, probs ++ ["each check needs a name and a run command"]}
      end)

    {checks, problems}
  end

  defp checks(_), do: {[], ["checks must be a list"]}

  @doc "Detected commands with the model's proposal merged in (SET-11)."
  def merge(detected, proposed) do
    by_name = Map.new(proposed.checks, &{&1.name, &1})
    names = MapSet.new(detected.checks, & &1.name)

    %{
      setup: Enum.uniq(detected.setup ++ proposed.setup),
      fix: Enum.uniq(detected.fix ++ proposed.fix),
      checks:
        Enum.map(detected.checks, &Map.get(by_name, &1.name, &1)) ++
          Enum.reject(proposed.checks, &MapSet.member?(names, &1.name)),
      protect: Enum.uniq(detected.protect ++ proposed.protect)
    }
  end

  defp instructions do
    """
    You configure Kogen for an existing software project. Kogen runs the project's setup commands \
    before each build, its fixers after each builder round, and its checks (the project's fast \
    regression suite) before every commit. From the project's own sources below (README, build \
    files, Makefile, CI workflows) and the commands Kogen already detected, propose:

    - setup: commands that install dependencies and prepare test databases or assets;
    - fix: deterministic formatters that rewrite files;
    - checks: each the single command the sources name for one tool (format check, compile with \
    warnings as errors, linter, type checker, security or dependency audit, tests), named in \
    lowercase with dashes; not an aggregate alias or target that runs several of them, and nothing \
    that deploys, publishes or needs credentials;
    - protect: tracked configuration files of those checks (linter rules, formatter settings, \
    suppression files).

    Propose only commands the sources name or Kogen detected. Kogen runs every command once on the \
    committed tree and keeps only those that pass, so do not leave a check out because it might \
    fail. Answer by calling submit_configuration once; empty lists are fine.
    """
  end

  defp submit_def do
    strings = %{"type" => "array", "items" => %{"type" => "string"}}

    %{
      "type" => "function",
      "name" => "submit_configuration",
      "strict" => false,
      "description" =>
        "The project's setup commands, fixers, checks and protected check configuration.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "setup" => strings,
          "fix" => strings,
          "checks" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{"name" => %{"type" => "string"}, "run" => %{"type" => "string"}},
              "required" => ["name", "run"]
            }
          },
          "protect" => strings
        },
        "required" => ["setup", "fix", "checks", "protect"]
      }
    }
  end

  # ---- SET-12, SET-13: run everything on a copy of the committed tree ----

  # The working tree with its ignored folders, every changed path reset to HEAD or removed.
  defp committed_copy!(root, clone, tracked) do
    File.mkdir_p!(clone)
    Tools.copy_tree(root, clone)
    changed = Git.changed_paths(root)
    Enum.each(changed, &File.rm_rf(Path.join(clone, &1)))

    case Enum.filter(changed, &(&1 in tracked)) do
      [] ->
        :ok

      restore ->
        cmd =
          "git archive --format=tar HEAD -- #{Enum.map_join(restore, " ", &shell_quote/1)} | tar -xf - -C #{shell_quote(clone)}"

        r = Bridge.exec(cmd, root)
        if r.status != 0, do: raise("restoring the committed files for init failed: #{r.output}")
    end
  end

  defp verify(root, clone, candidates, runner) do
    # Setup runs before every Build, so each entry must run twice on the same tree (SET-12).
    {setup, left_out} =
      candidates.setup
      |> Enum.with_index(1)
      |> Enum.reduce({[], []}, fn {cmd, n}, {kept, out} ->
        Bridge.progress("kogen: running setup-#{n}: #{cmd}")
        r = Bridge.exec(cmd, clone)

        cond do
          r.status != 0 ->
            {kept, out ++ ["setup-#{n} (#{cmd}) failed with status #{r.status}"]}

          true ->
            first = tree_state(root, clone)
            Bridge.progress("kogen: running setup-#{n} again: #{cmd}")
            again = Bridge.exec(cmd, clone)
            second = tree_state(root, clone)

            cond do
              again.status != 0 ->
                {kept,
                 out ++
                   [
                     "setup-#{n} (#{cmd}) is not repeatable: its second run failed with status #{again.status}"
                   ]}

              first != second ->
                changed =
                  Map.keys(first)
                  |> Kernel.++(Map.keys(second))
                  |> Enum.uniq()
                  |> Enum.filter(&(first[&1] != second[&1]))
                  |> Enum.sort()

                {kept,
                 out ++
                   [
                     "setup-#{n} (#{cmd}) is not repeatable: its second run changed #{Enum.join(changed, ", ")}"
                   ]}

              true ->
                {kept ++ [cmd], out}
            end
        end
      end)

    {acceptance, how, bridge, setup} =
      if runner, do: existing_runner(clone, runner, setup), else: add_bridge(clone, setup)

    {checks, left_out} =
      Enum.reduce(candidates.checks, {[], left_out}, fn check, {kept, out} ->
        Bridge.progress("kogen: checking #{check.name}: #{check.run}")
        r = Bridge.exec(check.run, clone)

        if r.status == 0,
          do: {kept ++ [check], out},
          else: {kept, out ++ ["#{check.name} (#{check.run}) failed with status #{r.status}"]}
      end)

    %{
      setup: setup,
      fix: candidates.fix,
      checks: checks,
      protect: if(checks == [], do: [], else: candidates.protect),
      acceptance: acceptance,
      how: how,
      bridge: bridge,
      left_out: left_out,
      files: if(bridge, do: %{@steps_readme_path => @steps_readme}, else: %{})
    }
  end

  # Paths of the copy that differ from HEAD (by the repository's own ignore rules), with digests.
  defp tree_state(root, clone) do
    git_dir = root |> Git.ok!(["rev-parse", "--absolute-git-dir"]) |> String.trim()

    {out, 0} =
      System.cmd(
        "git",
        [
          "--git-dir=" <> git_dir,
          "--work-tree=" <> clone,
          "--no-optional-locks",
          "status",
          "--porcelain=v1",
          "-z",
          "--untracked-files=all"
        ],
        env: [{"GIT_OPTIONAL_LOCKS", "0"}]
      )

    for <<_xy::binary-size(2), " ", path::binary>> <- String.split(out, "\0", trim: true),
        into: %{} do
      file = Path.join(clone, path)
      {path, if(File.regular?(file), do: :crypto.hash(:sha256, File.read!(file)), else: :absent)}
    end
  end

  defp existing_runner(clone, steps_dir, setup) do
    acceptance = %{run: Detect.acceptance_command(steps_dir, :project), steps_dir: steps_dir}

    case Readiness.runner_check(clone, acceptance.run) do
      :ok -> {acceptance, "existing Cucumber runner, steps in #{steps_dir}", false, setup}
      {:failed, why, _output} -> {nil, "not configured: #{why}", false, setup}
    end
  end

  defp add_bridge(clone, setup) do
    File.mkdir_p!(Path.join(clone, "features/steps"))
    File.write!(Path.join(clone, @steps_readme_path), @steps_readme)

    acceptance = %{
      run: Detect.acceptance_command("features/steps", :kogen),
      steps_dir: "features/steps"
    }

    case Readiness.runner_check(clone, acceptance.run) do
      :ok -> {acceptance, "Cucumber bridge added in features/steps", true, setup}
      {:failed, why, _output} -> {nil, "not configured: #{why}", false, setup}
    end
  end

  # ---- writing and committing ----

  defp write_files(root, head, config, files) do
    File.mkdir_p!(Path.join(root, ".kogen"))
    File.write!(Path.join(root, Config.path()), config)

    committed =
      if head,
        do: Git.show(root, head, ".gitignore") || "",
        else: read(Path.join(root, ".gitignore"))

    ignore = with_line(committed, @ignore)

    File.write!(Path.join(root, ".gitignore"), ignore)

    for {path, text} <- files do
      File.mkdir_p!(Path.dirname(Path.join(root, path)))
      File.write!(Path.join(root, path), text)
    end
  end

  defp with_line(text, line) do
    cond do
      line in String.split(text, "\n") -> text
      text == "" or String.ends_with?(text, "\n") -> text <> line <> "\n"
      true -> text <> "\n" <> line <> "\n"
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, text} -> text
      _ -> ""
    end
  end

  defp next_lines(config) do
    if config.acceptance_run == nil or config.steps_dir == nil, do: Bridge.puts(@next_acceptance)
    if config.checks == [], do: Bridge.puts(@next_checks)
  end

  # A plain git commit of exactly these paths; other staged or unstaged changes stay out.
  defp commit!(root, paths, head) do
    subject = if head, do: "Add Kogen configuration", else: "Initial commit"
    Git.ok!(root, ["add", "--" | paths])
    msg = Kogen.tmp_path("kogen-init-msg")
    File.write!(msg, subject <> "\n")

    result =
      Bridge.exec(
        "git commit -q -F #{shell_quote(msg)} -- #{Enum.map_join(paths, " ", &shell_quote/1)}",
        root
      )

    File.rm(msg)

    if result.status != 0 do
      unstage = if head, do: ["restore", "--staged", "--"], else: ["rm", "-q", "--cached", "--"]
      Git.run(root, unstage ++ paths)
      lines = result.output |> String.trim() |> String.split("\n")

      Error.raise!(
        "environment",
        "commit_failed",
        "git commit failed (status #{result.status}); the configuration is left uncommitted",
        3,
        lines
      )
    end

    root |> Git.ok!(["rev-parse", "HEAD"]) |> binary_part(0, 8)
  end

  def shell_quote(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"
end
