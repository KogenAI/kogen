defmodule Kogen.IntentTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Kogen.{Config, Intent}

  setup do
    root = temp_dir("intent")
    home = Path.join(root, "home")
    File.mkdir_p!(home)

    env = [
      {"HOME", home},
      {"GIT_CONFIG_GLOBAL", Path.join(home, ".gitconfig")},
      {"GIT_CONFIG_NOSYSTEM", "1"}
    ]

    old_env = Enum.map(env, fn {key, _} -> {key, System.get_env(key)} end)
    Enum.each(env, fn {key, value} -> System.put_env(key, value) end)

    on_exit(fn ->
      Enum.each(old_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf!(root)
    end)

    {:ok, temp: root}
  end

  test "SHP-5: formatted Acceptance lists read and lint with leading blank lines", %{temp: root} do
    init_git!(root)
    feature = Intent.feature("reading-time")
    steps = "features/steps/reading_time.js"

    write_file!(
      root,
      feature,
      "Feature: Reading time\n  Scenario: Estimate\n    Then it is shown\n"
    )

    write_file!(root, steps, "// acceptance steps\n")

    for spacing <- ["", "\n", "\n \t\n"] do
      write_file!(root, Intent.intent_md("reading-time"), """
      # Reading time
      Slug: reading-time
      Model: not applicable — display calculation
      Acceptance:
      #{spacing}- #{feature}
      - #{steps}

      ## Decisions

      - Show the estimate (source: request)

      ## Feasibility

      - none

      ## Tests

      - estimate: detail route displays reading time (regression)
      """)

      assert Intent.read(root, "reading-time").acceptance == [feature, steps]
      assert {:ok, intent, [_scenario]} = Intent.check(root, "reading-time")
      assert intent.acceptance == [feature, steps]
    end
  end

  test "SHP-5: Acceptance only skips blanks before the first bullet", %{temp: root} do
    path = Intent.intent_md("reading-time")
    feature = Intent.feature("reading-time")

    for boundary <- ["", "ordinary text", "## Decisions"] do
      text = "Acceptance:\n\n- #{feature}\n#{boundary}\n- unrelated\n"
      assert Intent.read(root, "reading-time", %{path => text}).acceptance == [feature]
    end

    text = "Acceptance:\n\n## Decisions\n- unrelated\n"
    assert Intent.read(root, "reading-time", %{path => text}).acceptance == []
  end

  property "AUT-2 / VER-1: changing, adding, removing, or renaming any baseline file changes its hash" do
    check all(
            contents <-
              StreamData.list_of(StreamData.string(:alphanumeric, max_length: 24),
                min_length: 1,
                max_length: 6
              )
          ) do
      root = temp_dir("hash-property")

      paths =
        contents
        |> Enum.with_index()
        |> Enum.map(fn {_content, i} -> "baseline/file-#{i}.txt" end)

      try do
        Enum.zip(paths, contents)
        |> Enum.each(fn {path, content} -> write_file!(root, path, content) end)

        original_hash = Intent.hash(root, paths)
        first = hd(paths)
        first_content = hd(contents)

        write_file!(root, first, first_content <> "changed")
        assert Intent.hash(root, paths) != original_hash
        write_file!(root, first, first_content)

        added = "baseline/added.txt"
        write_file!(root, added, "new baseline file")
        assert Intent.hash(root, paths ++ [added]) != original_hash
        File.rm!(Path.join(root, added))

        File.rm!(Path.join(root, first))
        assert Intent.hash(root, List.delete(paths, first)) != original_hash
        write_file!(root, first, first_content)

        renamed = "baseline/renamed.txt"
        File.rename!(Path.join(root, first), Path.join(root, renamed))
        renamed_paths = paths |> List.delete(first) |> Kernel.++([renamed])
        assert Intent.hash(root, renamed_paths) != original_hash
      after
        File.rm_rf!(root)
      end
    end
  end

  property "AUT-2: the approval hash does not depend on baseline listing order" do
    check all(
            contents <-
              StreamData.list_of(StreamData.string(:alphanumeric, max_length: 24),
                min_length: 2,
                max_length: 6
              )
          ) do
      root = temp_dir("hash-order-property")

      paths =
        contents
        |> Enum.with_index()
        |> Enum.map(fn {_content, i} -> "baseline/file-#{i}.txt" end)

      try do
        Enum.zip(paths, contents)
        |> Enum.each(fn {path, content} -> write_file!(root, path, content) end)

        expected = Intent.hash(root, paths)
        assert Intent.hash(root, Enum.reverse(paths)) == expected
        assert Intent.hash(root, Enum.shuffle(paths)) == expected
      after
        File.rm_rf!(root)
      end
    end
  end

  test "VER-1: protect paths, folders, and globs select the matching Git files and no neighbors",
       %{temp: temp} do
    root = Path.join(temp, "project")
    File.mkdir_p!(root)
    init_git!(root)

    files = [
      {".credo.exs", "rules"},
      {".credo.exs.bak", "backup"},
      {"config/linter.exs", "config"},
      {"config/nested/rules.exs", "nested config"},
      {"configurator/linter.exs", "neighbor"},
      {"checks/unit.yml", "unit"},
      {"checks/nested/integration.yml", "integration"},
      {"checks/unit.yaml", "other extension"},
      {"style/base.cfg", "direct"},
      {"style/nested/extra.cfg", "nested"},
      {"style-backup/base.cfg", "neighbor"},
      {"notes.txt", "unprotected"}
    ]

    Enum.each(files, fn {path, contents} -> write_file!(root, path, contents) end)
    write_file!(root, ".gitignore", "checks/ignored.yml\n")
    git!(root, ["add", "."])
    git!(root, ["commit", "-m", "fixture"])
    write_file!(root, "checks/ignored.yml", "ignored")

    protected =
      Intent.protected(root, %Config{
        protect: [".credo.exs", "config/", "checks/**/*.yml", "style/*.cfg"]
      })

    assert protected == [
             ".credo.exs",
             "checks/nested/integration.yml",
             "checks/unit.yml",
             "config/linter.exs",
             "config/nested/rules.exs",
             "style/base.cfg"
           ]
  end

  defp init_git!(root) do
    git!(root, ["init", "--quiet"])
    git!(root, ["config", "user.name", "Kogen Test"])
    git!(root, ["config", "user.email", "kogen-test@example.test"])
    git!(root, ["config", "commit.gpgsign", "false"])
    git!(root, ["config", "core.hooksPath", Path.join(root, "disabled-hooks")])
  end

  defp git!(root, args) do
    {output, status} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    assert status == 0, "git #{Enum.join(args, " ")} failed: #{output}"
    output
  end

  defp write_file!(root, path, contents) do
    full_path = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, contents)
  end

  defp temp_dir(prefix) do
    path = Path.join(System.tmp_dir!(), "kogen-#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end
end
