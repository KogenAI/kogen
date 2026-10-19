defmodule Kogen.Snapshot do
  @moduledoc """
  The candidate (VER-10) as a Git tree: every tracked file and every untracked file not ignored,
  with content and mode, except other uncommitted Intents' whole folders. It is built in a temporary
  index seeded from the start HEAD, so the user's index is untouched until the commit (GIT-4)
  and nothing staged before the Build slips in.
  """
  alias Kogen.Git

  @doc "The tree id of the candidate, built on the start HEAD's tree."
  def tree(root, start, excluded) do
    index = Kogen.tmp_path("kogen-index")

    try do
      env = [{"GIT_INDEX_FILE", index}]
      excludes = Enum.map(excluded, &":(exclude,literal)#{&1}")
      Git.ok!(root, ["read-tree", start], env: env)
      Git.ok!(root, ["add", "-A", "--", "." | excludes], env: env)
      root |> Git.ok!(["write-tree"], env: env) |> String.trim()
    after
      File.rm(index)
    end
  end

  @doc "Materialize only the candidate tree into a new disposable directory."
  def materialize(root, tree, dir) do
    File.mkdir_p!(dir)
    format = root |> Git.ok!(["rev-parse", "--show-object-format"]) |> String.trim()
    Git.ok!(dir, ["init", "-q", "--template=", "--object-format=#{format}"])

    entries =
      root
      |> Git.ok!(["ls-tree", "-r", "-z", tree])
      |> String.split("\0", trim: true)

    indexed =
      for entry <- entries do
        [metadata, path] = String.split(entry, "\t", parts: 2)
        [mode, type, object] = String.split(metadata, " ")
        target = Path.join(dir, path)
        File.mkdir_p!(Path.dirname(target))

        case {mode, type} do
          {"120000", "blob"} ->
            bytes = Git.ok!(root, ["cat-file", "blob", object])
            File.ln_s!(bytes, target)
            temporary = Path.join(dir, ".git/kogen-symlink-input")
            File.write!(temporary, bytes)
            Git.ok!(dir, ["hash-object", "-w", "--no-filters", "--", temporary])
            File.rm!(temporary)

          {_, "blob"} ->
            File.write!(target, Git.ok!(root, ["cat-file", "blob", object]))
            File.chmod!(target, if(mode == "100755", do: 0o755, else: 0o644))
            Git.ok!(dir, ["hash-object", "-w", "--no-filters", "--", target])

          {_, "commit"} ->
            File.mkdir_p!(target)
        end

        {mode, object, path}
      end

    # A new local index/HEAD makes declared Git commands usable without importing
    # the user's metadata, hooks, history, ignored outputs or dependency folders.
    # Populate from exact blob identities, bypassing checkout/attribute filters.
    for batch <- Enum.chunk_every(indexed, 100) do
      args =
        Enum.flat_map(batch, fn {mode, object, path} -> ["--cacheinfo", mode, object, path] end)

      Git.ok!(dir, ["update-index", "--add" | args])
    end

    ^tree = dir |> Git.ok!(["write-tree"]) |> String.trim()

    commit =
      dir
      |> Git.ok!([
        "-c",
        "user.name=Kogen Verification",
        "-c",
        "user.email=verification@kogen.invalid",
        "-c",
        "commit.gpgsign=false",
        "commit-tree",
        tree,
        "-m",
        "Clean candidate verification"
      ])
      |> String.trim()

    Git.ok!(dir, ["update-ref", "HEAD", commit])
    paths = Enum.map(indexed, &elem(&1, 2))
    gitlinks = for {"160000", object, path} <- indexed, into: %{}, do: {path, object}
    {paths, inputs(dir, paths), gitlinks}
  end

  defp inputs(dir, paths) do
    Map.new(paths, fn path ->
      full = Path.join(dir, path)

      value =
        case File.lstat(full) do
          {:ok, %{type: :symlink}} ->
            {:symlink, File.read_link!(full)}

          {:ok, %{type: :regular, mode: mode}} ->
            {:file, Bitwise.band(mode, 0o111), :crypto.hash(:sha256, File.read!(full))}

          {:ok, %{type: type}} ->
            type

          {:error, :enoent} ->
            :missing

          {:error, :enotdir} ->
            :missing
        end

      {path, value}
    end)
  end

  @doc "Raw candidate input mutations and nonignored additions in a verification directory."
  def mutations(dir, {paths, before, gitlinks}) do
    index = Kogen.tmp_path("kogen-verify-index")

    others =
      try do
        # Commands may stage generated files. Enumerate filesystem inputs without
        # trusting that index, so staging cannot hide a nonignored addition.
        env = [{"GIT_INDEX_FILE", index}]
        Git.ok!(dir, ["read-tree", "--empty"], env: env)

        dir
        |> Git.ok!(["ls-files", "--others", "--exclude-standard", "-z"], env: env)
        |> String.split("\0", trim: true)
      after
        File.rm(index)
      end

    after_inputs = inputs(dir, paths)

    additions =
      Enum.reject(others -- paths, &Map.has_key?(gitlinks, String.trim_trailing(&1, "/")))

    changed_gitlinks =
      for {path, object} <- gitlinks,
          full = Path.join(dir, path),
          File.dir?(full),
          Git.root(full) == full,
          Git.head(full) != object or
            tree(full, object, []) !=
              String.trim(Git.ok!(full, ["rev-parse", "#{object}^{tree}"])),
          do: path

    Enum.uniq(
      Enum.filter(paths, &(before[&1] != after_inputs[&1])) ++ additions ++ changed_gitlinks
    )
  end

  @doc "Paths that differ between two trees."
  def changed(root, a, b) do
    root
    |> Git.ok!(["diff", "--name-only", "-z", "--no-renames", a, b])
    |> String.split("\0", trim: true)
  end

  @doc "The unified diff between two trees."
  def diff(root, a, b, paths \\ :all)
  def diff(_root, _a, _b, []), do: ""

  def diff(root, a, b, paths) do
    selection = if paths == :all, do: [], else: ["--" | Enum.map(paths, &":(literal)#{&1}")]

    Git.ok!(
      root,
      ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", a, b] ++ selection
    )
  end
end
