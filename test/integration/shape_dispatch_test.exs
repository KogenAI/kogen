defmodule Kogen.Integration.ShapeDispatchTest do
  use ExUnit.Case, async: true
  alias Kogen.{Config, ShapeBatch, ShapeContext}

  setup do
    root = Kogen.tmp_path("kogen-dispatch")
    File.mkdir_p!(Path.join(root, "features/steps"))
    on_exit(fn -> File.rm_rf!(root) end)
    git!(root, ["init", "-q"])
    git!(root, ["config", "user.name", "Fixture"])
    git!(root, ["config", "user.email", "fixture@example.invalid"])
    git!(root, ["config", "commit.gpgsign", "false"])
    File.write!(Path.join(root, ".gitignore"), ".kogen/local/\n")
    File.write!(Path.join(root, "guard.txt"), "protected")
    git!(root, ["add", "."])
    git!(root, ["commit", "-qm", "baseline"])
    config = %Config{steps_dir: "features/steps", protect: ["guard.txt"]}
    sh = %{root: root, slug: "fixture", config: config}

    brief = %{
      "revision" => ShapeContext.revision(root) |> JSON.encode!() |> JSON.decode!(),
      "outcomes" => "literal input",
      "interfaces" => "exact output",
      "transitions" => "stateless",
      "fixtures" => "runner and red baseline",
      "exclusions" => "no authority",
      "protected_paths" => ["guard.txt", ".kogen/project.yaml"],
      "artifacts" => [%{"path" => "features/steps/draft.js", "expectation" => "agreement"}]
    }

    job = %{
      "id" => "one",
      "role" => "draft",
      "scope" => "one exact independent task",
      "paths" => [],
      "owns" => ["features/steps/draft.js"]
    }

    %{root: root, sh: sh, brief: brief, job: job}
  end

  test "ownership and boundary refusal precedes calls and never alters raw index", c do
    index = File.read!(Path.join(c.root, ".git/index"))
    assert {:ok, _, _} = ShapeBatch.validate(%{"brief" => c.brief, "jobs" => [c.job]}, c.sh)

    for owns <- [
          ["../escape"],
          ["guard.txt"],
          ["features/steps"],
          ["features/steps/a.js", "features/steps/a.js"],
          ["features/steps/a", "features/steps/a/b.js"]
        ] do
      assert %{status: "refused", jobs: []} =
               ShapeBatch.run(%{"brief" => c.brief, "jobs" => [%{c.job | "owns" => owns}]}, c.sh)
    end

    File.ln_s!(System.tmp_dir!(), Path.join(c.root, "features/steps/link"))

    assert {:error, _} =
             ShapeBatch.validate(
               %{
                 "brief" => c.brief,
                 "jobs" => [%{c.job | "owns" => ["features/steps/link/out.js"]}]
               },
               c.sh
             )

    assert {:error, _} =
             ShapeBatch.validate(%{"brief" => c.brief, "jobs" => [c.job, c.job]}, c.sh)

    second = %{c.job | "id" => "two", "owns" => ["features/steps/../steps/draft.js"]}

    assert {:error, _} =
             ShapeBatch.validate(%{"brief" => c.brief, "jobs" => [c.job, second]}, c.sh)

    assert File.read!(Path.join(c.root, ".git/index")) == index
  end

  test "draft boundaries reject unsupported artifacts, even with an expectation", c do
    for target <- [".kogen/intents/fixture/extra.txt", "features/steps/../steps/draft.js"] do
      brief = %{c.brief | "artifacts" => [%{"path" => target, "expectation" => "draft"}]}
      job = %{c.job | "owns" => [target]}
      assert {:error, _} = ShapeBatch.validate(%{"brief" => brief, "jobs" => [job]}, c.sh)
    end

    assert {:error, _} =
             ShapeBatch.validate(
               %{"brief" => %{c.brief | "artifacts" => []}, "jobs" => [c.job]},
               c.sh
             )
  end

  test "an existing editable step is a valid draft target, with current boundaries", c do
    File.write!(Path.join(c.root, "features/steps/draft.js"), "// existing shared step\n")

    brief =
      Map.put(
        c.brief,
        "revision",
        ShapeContext.revision(c.root) |> JSON.encode!() |> JSON.decode!()
      )

    assert {:ok, _, _} = ShapeBatch.validate(%{"brief" => brief, "jobs" => [c.job]}, c.sh)
  end

  test "context is index-first and explicit excerpts retain exact frozen provenance", c do
    path = "features/steps/source.js"

    bytes =
      String.duplicate("// unrelated prefix\n", 100) <>
        "Then(\n  'the literal needle is {string}',\n  function () {}\n);\n"

    File.write!(Path.join(c.root, path), bytes)
    File.write!(Path.join(c.root, "image.bin"), <<0, 255, 42>>)
    original_dir = Path.join(c.root, ".kogen/local/original")

    {text, index} =
      ShapeContext.index(c.root, "fixture", c.sh.config, "literal needle", %{path => bytes},
        owned: [],
        original_dir: original_dir
      )

    entry = Enum.find(index.entries, &(&1.path == path))
    assert entry.ownership == "shared"
    assert entry.source == Path.join(original_dir, path)
    assert entry.sha256 == ShapeContext.hash(bytes)
    assert text =~ "the literal needle is {string}"
    refute text =~ "Excerpt: "
    assert index.root == c.root
    ordinary = Enum.find(index.entries, &(&1.path == "image.bin"))
    refute Map.has_key?(ordinary, :source)
    refute Map.has_key?(ordinary, :revision)
    excerpt = ShapeContext.excerpt(entry, bytes, ["literal needle"])
    assert excerpt =~ ~s("start_line":97)
    [header, _body] = String.split(excerpt, "\n", parts: 2)

    assert header
           |> String.replace_prefix("Excerpt: ", "")
           |> JSON.decode!()
           |> Map.keys()
           |> Enum.sort() ==
             ~w(end_line path sha256 start_line)

    assert Enum.any?(entry.signatures, &(&1.start_line == 101 and &1.end_line == 102))
    assert Enum.any?(index.entries, &(&1.path == "image.bin"))

    {again, _} =
      ShapeContext.index(c.root, "fixture", c.sh.config, "literal needle", %{path => bytes},
        owned: [],
        original_dir: original_dir
      )

    assert again == text
  end

  test "revision notices nonignored untracked drift without real-index writes", c do
    index = File.read!(Path.join(c.root, ".git/index"))
    File.write!(Path.join(c.root, "new.txt"), "drift")
    refute ShapeContext.revision(c.root).tree == c.brief["revision"]["tree"]
    assert {:error, _} = ShapeBatch.validate(%{"brief" => c.brief, "jobs" => [c.job]}, c.sh)
    assert File.read!(Path.join(c.root, ".git/index")) == index
  end

  defp git!(root, args) do
    {out, status} =
      System.cmd("git", args,
        cd: root,
        stderr_to_stdout: true,
        env: [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}]
      )

    assert status == 0, out
    out
  end
end
