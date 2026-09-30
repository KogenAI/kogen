defmodule Kogen.CwdIsolationGuardTest do
  use ExUnit.Case, async: true

  # The working directory is process-global. A module that shares the outer
  # ExUnit VM with other async modules must never change it: every concurrent
  # test that reads a relative path, or starts a command without `cd:`, would
  # race. Tests that need a different cwd belong to `Kogen.IsolatedCase`, whose
  # test bodies run in a fresh VM.
  @root Path.expand("../..", __DIR__)

  # Path (relative to the checkout) => why the module may mention a cwd change
  # without using `Kogen.IsolatedCase`. Keep this empty unless the pattern is
  # provably safe.
  @allowlist %{}

  @cwd_change ~r/(?:\bFile\.cd!?\(|:file\.set_cwd\(|\bFile\.cd!?\s*\|>)/

  test "no non-isolated test module changes the shared VM's working directory" do
    offenders =
      for path <- test_sources(),
          relative = Path.relative_to(path, @root),
          not Map.has_key?(@allowlist, relative),
          not isolated?(path),
          Regex.match?(@cwd_change, code(path)),
          do: relative

    assert offenders == [],
           "these modules run in the shared async VM but change the working directory " <>
             "(use Kogen.IsolatedCase, or pass an explicit root / `cd:`): #{inspect(offenders)}"
  end

  test "non-isolated test modules never use a support fixture that changes the working directory" do
    cwd_changing_modules =
      for path <- Path.wildcard(Path.join(@root, "test/support/**/*.ex")),
          source = code(path),
          Regex.match?(@cwd_change, source),
          [_, name] <- Regex.scan(~r/^defmodule ([\w.]+) do/m, source),
          do: name

    offenders =
      for path <- test_sources(),
          String.ends_with?(path, "_test.exs"),
          not isolated?(path),
          relative = Path.relative_to(path, @root),
          not Map.has_key?(@allowlist, relative),
          source = code(path),
          name <- cwd_changing_modules,
          uses_module?(source, name),
          do: {relative, name}

    assert offenders == []
  end

  test "the allowlist has no stale entries" do
    for {relative, reason} <- @allowlist do
      assert File.regular?(Path.join(@root, relative)), "stale allowlist entry: #{relative}"
      assert String.trim(reason) != ""
    end
  end

  # `Kogen.IsolatedCase` runs `setup` callbacks in the parent VM as well as the
  # child, so a setup that mutates process-global state (environment, cwd,
  # application config) races every other module's setup unless the mutation
  # sits behind `WorkspaceFixture.isolated_child?()`. Local helpers called from
  # a setup are followed.
  @global_mutations [
    {[:System], :put_env},
    {[:System], :delete_env},
    {[:File], :cd},
    {[:File], :cd!},
    {[:Application], :put_env},
    {[:Application], :delete_env},
    {[:WorkspaceFixture], :create!},
    {[:WorkspaceFixture], :build!}
  ]

  test "IsolatedCase setup callbacks mutate global state only behind isolated_child?()" do
    offenders =
      for path <- test_sources(),
          String.ends_with?(path, "_test.exs"),
          isolated?(path),
          relative = Path.relative_to(path, @root),
          not Map.has_key?(@allowlist, relative),
          ast = Code.string_to_quoted!(File.read!(path)),
          {kind, line} <- unguarded_setup_mutations(ast),
          do: "#{relative}:#{line} (#{kind})"

    assert offenders == [],
           "these Kogen.IsolatedCase setup callbacks run in the parent VM and mutate env, " <>
             "cwd or fixtures outside an isolated_child?() guard: #{inspect(offenders)}"
  end

  test "the setup mutation scan flags an unguarded put_env and accepts a guarded one" do
    unguarded =
      Code.string_to_quoted!(~S"""
      setup do
        System.put_env("A", "1")
        :ok
      end
      """)

    guarded =
      Code.string_to_quoted!(~S"""
      setup do
        if WorkspaceFixture.isolated_child?() do
          System.put_env("A", "1")
        end
        :ok
      end
      """)

    via_helper =
      Code.string_to_quoted!(~S"""
      setup do
        prepare()
        :ok
      end
      defp prepare, do: File.cd!("x")
      """)

    assert [{_, _}] = unguarded_setup_mutations(unguarded)
    assert unguarded_setup_mutations(guarded) == []
    assert [{_, _}] = unguarded_setup_mutations(via_helper)
  end

  defp unguarded_setup_mutations(ast) do
    helpers = local_functions(ast)

    ast
    |> setup_bodies()
    |> Enum.flat_map(&mutations(&1, helpers, MapSet.new()))
  end

  defp setup_bodies(ast) do
    {_, bodies} =
      Macro.prewalk(ast, [], fn
        {name, _, args} = node, acc when name in [:setup, :setup_all] and is_list(args) ->
          {node, [args | acc]}

        node, acc ->
          {node, acc}
      end)

    bodies
  end

  defp local_functions(ast) do
    {_, defs} =
      Macro.prewalk(ast, %{}, fn
        {kind, _, [{:when, _, [head | _]}, body]} = node, acc when kind in [:def, :defp] ->
          {node, put_def(acc, head, body)}

        {kind, _, [head, body]} = node, acc when kind in [:def, :defp] ->
          {node, put_def(acc, head, body)}

        node, acc ->
          {node, acc}
      end)

    defs
  end

  defp put_def(acc, {name, _, _}, body) when is_atom(name),
    do: Map.update(acc, name, [body], &[body | &1])

  defp put_def(acc, _head, _body), do: acc

  # Walk a node, skipping any `if`/`unless`/`case`/`cond`/`with` that mentions
  # `isolated_child?` (the guard), and follow calls to local helpers once each.
  defp mutations(node, helpers, seen) do
    {_, found} =
      Macro.prewalk(node, [], fn
        {form, _, _} = guarded, acc when form in [:if, :unless, :case, :cond, :with] ->
          if mentions_guard?(guarded), do: {:skip, acc}, else: {guarded, acc}

        {{:., _, [{:__aliases__, _, mod}, fun]}, meta, _} = call, acc ->
          if global_mutation?(mod, fun),
            do: {call, [{"#{Enum.join(mod, ".")}.#{fun}", meta[:line]} | acc]},
            else: {call, acc}

        {name, meta, args} = call, acc when is_atom(name) and is_list(args) ->
          {call, acc ++ follow(name, meta, helpers, seen)}

        other, acc ->
          {other, acc}
      end)

    Enum.uniq(found)
  end

  defp global_mutation?(mod, fun),
    do: Enum.any?(@global_mutations, fn {m, f} -> List.last(mod) == List.last(m) and f == fun end)

  defp follow(name, meta, helpers, seen) do
    if Map.has_key?(helpers, name) and not MapSet.member?(seen, name) do
      helpers
      |> Map.fetch!(name)
      |> Enum.flat_map(&mutations(&1, helpers, MapSet.put(seen, name)))
      |> Enum.map(fn {kind, _} ->
        {kind <> " via " <> Atom.to_string(name) <> "()", meta[:line]}
      end)
    else
      []
    end
  end

  defp mentions_guard?(node) do
    {_, found} =
      Macro.prewalk(node, false, fn
        {{:., _, [_, :isolated_child?]}, _, _} = n, _ -> {n, true}
        {:isolated_child?, _, _} = n, _ -> {n, true}
        n, acc -> {n, acc}
      end)

    found
  end

  defp test_sources do
    Path.wildcard(Path.join(@root, "test/**/*.exs"))
    |> Enum.reject(&(Path.expand(&1) == Path.expand(__ENV__.file)))
  end

  defp isolated?(path), do: File.read!(path) =~ ~r/^\s*use Kogen\.IsolatedCase\b/m

  # Source without comment-only lines, so prose about the pattern is not code.
  defp code(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(&String.match?(&1, ~r/^\s*#/))
    |> Enum.join("\n")
  end

  defp uses_module?(source, name) do
    short = name |> String.split(".") |> List.last()
    Regex.match?(~r/\b#{Regex.escape(name)}\b/, source) or alias_mentions?(source, name, short)
  end

  defp alias_mentions?(source, name, short) do
    parent = name |> String.split(".") |> Enum.drop(-1) |> Enum.join(".")

    Regex.match?(~r/alias\s+#{Regex.escape(name)}\b/, source) or
      (parent != "" and
         Regex.match?(~r/alias\s+#{Regex.escape(parent)}\.\{[^}]*\b#{short}\b[^}]*\}/, source))
  end
end
