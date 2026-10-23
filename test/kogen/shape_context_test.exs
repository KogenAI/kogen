defmodule Kogen.ShapeContextTest do
  use ExUnit.Case, async: true
  alias Kogen.ShapeContext

  test "navigation has fixed shape across empty, small and large candidate trees" do
    root = Kogen.tmp_path("shape-navigation")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    Kogen.Git.ok!(root, ["init", "-q"])
    Kogen.Git.ok!(root, ["config", "user.name", "Context Fixture"])
    Kogen.Git.ok!(root, ["config", "user.email", "context@example.invalid"])
    Kogen.Git.ok!(root, ["config", "commit.gpgsign", "false"])
    Kogen.Git.ok!(root, ["config", "core.hooksPath", "/dev/null"])
    Kogen.Git.ok!(root, ["commit", "--allow-empty", "-qm", "Initial"])
    head = Kogen.Git.head(root)

    descriptors =
      for count <- [0, 1, 1800] do
        if count > 0 do
          for n <- 1..count do
            path = Path.join(root, "deep/source/file-#{n}.ex")
            File.mkdir_p!(Path.dirname(path))
            File.write!(path, "def declaration_#{n}, do: :ok\n")
          end
        end

        {text, descriptor} = ShapeContext.navigation(root)
        assert Map.keys(descriptor) |> Enum.sort() == [:retrieval, :revision, :root]
        assert Map.keys(descriptor.revision) |> Enum.sort() == [:head, :tree]
        assert descriptor.root == Path.expand(root)
        assert descriptor.revision == ShapeContext.revision(root)
        assert descriptor.revision.head == head

        assert descriptor.retrieval ==
                 "read_file exact bytes and line ranges; list_files directories; search_text exact signatures"

        assert text == "Context navigation: " <> JSON.encode!(descriptor) <> "\n"
        assert length(String.split(text, "\n")) == 2
        assert byte_size(text) < 1024
        assert {text, descriptor} == ShapeContext.navigation(root)
        descriptor
      end

    assert descriptors |> Enum.map(& &1.revision.tree) |> Enum.uniq() |> length() == 3
    assert descriptors |> Enum.map(&byte_size(JSON.encode!(&1))) |> Enum.uniq() |> length() == 1
    {_, before} = ShapeContext.navigation(root)
    File.mkdir_p!(Path.join(root, ".kogen/local"))
    File.write!(Path.join(root, ".kogen/local/private"), "not navigation")
    assert {_, ^before} = ShapeContext.navigation(root)
    File.write!(Path.join(root, "deep/source/file-1.ex"), "changed candidate")
    {_, changed} = ShapeContext.navigation(root)
    refute changed.revision.tree == before.revision.tree
    assert changed.revision.head == head
  end

  test "explicit windows preserve adjacent line and UTF-8 byte bounds" do
    for count <- [79, 80, 81] do
      bytes = Enum.map_join(1..count, "\n", &"line #{&1}")
      {header, body} = render(bytes)
      assert header["start_line"] == 1
      assert header["end_line"] == min(count, 80)

      assert body ==
               bytes |> String.split("\n") |> Enum.take(80) |> Enum.map_join("", &(&1 <> "\n"))
    end

    for size <- [8191, 8192, 8193] do
      # Includes a multibyte codepoint; size includes the rendered newline.
      line = "é" <> String.duplicate("x", size - 3)
      {header, body} = render(line)
      assert byte_size(body) <= 8192
      assert String.valid?(body)
      assert body == if(size <= 8192, do: line <> "\n", else: "")
      assert header["end_line"] == if(size <= 8192, do: 1, else: 0)
    end
  end

  test "explicit windows do not invent a line after the source final newline" do
    for {bytes, expected, count} <- [
          {"", "", 0},
          {"one", "one\n", 1},
          {"one\n", "one\n", 1},
          {"\n", "\n", 1},
          {"one\n\n", "one\n\n", 2}
        ] do
      {header, body} = render(bytes)
      assert body == expected
      assert header["start_line"] == 1
      assert header["end_line"] == count
    end
  end

  defp render(bytes) do
    entry = %{
      path: "literal/é.txt",
      sha256: ShapeContext.hash(bytes),
      bytes: byte_size(bytes),
      signatures: [],
      ownership: "source"
    }

    [header, body] = ShapeContext.excerpt(entry, bytes, []) |> String.split("\n", parts: 2)
    header = header |> String.replace_prefix("Excerpt: ", "") |> JSON.decode!()
    assert Enum.sort(Map.keys(header)) == ~w(end_line path sha256 start_line)
    assert header["sha256"] == ShapeContext.hash(bytes)
    {header, body}
  end
end
