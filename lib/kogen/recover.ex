defmodule Kogen.Recover do
  @moduledoc "Explicit preservation and implementation-only cleanup of a completed protected blocker."
  alias Kogen.{Bridge, Build, Config, Error, Git, Intent, Lock, Run, Snapshot}

  def run(project, id, output) do
    root = Git.root!(project)

    try do
      lock = Build.lock!(root)

      try do
        recover(root, id, Path.expand(output))
      after
        Lock.release(lock)
      end
    rescue
      e in Error ->
        if e.reason in ["recovery_refused", "recovery_unsupported"],
          do: reraise(e, __STACKTRACE__)

        refuse!(Exception.message(e))

      e ->
        refuse!(Exception.message(e))
    end
  end

  defp refuse!(why, kind \\ "recovery_refused") do
    Error.raise!(
      "candidate",
      kind,
      "#{why}; inspect the run/receipt and checkout; correct the named fact or use ordinary Refine and fresh exact approval",
      1
    )
  end

  defp require!(true, _), do: :ok
  defp require!(_, why), do: refuse!(why)
  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp safe!(path) do
    Enum.reduce(tl(Path.split(Path.expand(path))), "/", fn part, parent ->
      full = Path.join(parent, part)

      case File.lstat(full) do
        {:ok, %{type: type}} when type in [:regular, :directory] -> :ok
        _ -> refuse!("unsafe/symlinked or missing custody: #{full}")
      end

      full
    end)
  end

  defp read!(path) do
    safe!(path)
    require!(File.regular?(path), "not regular custody: #{path}")
    File.read!(path)
  end

  defp recover(root, id, output) do
    unless is_binary(id) and Regex.match?(~r/^[a-f0-9]{8}$/, id),
      do: refuse!("unknown checkpoint", "recovery_unsupported")

    dir = Path.join(root, ".kogen/local/runs/#{id}")
    cp = Path.join(dir, "checkpoint.json")
    unless File.exists?(cp), do: refuse!("absent checkpoint", "recovery_unsupported")
    bytes = read!(cp)

    case JSON.decode(bytes) do
      {:ok, %{"version" => v}} when v != 3 ->
        refuse!("legacy checkpoint version #{inspect(v)}", "recovery_unsupported")

      _ ->
        :ok
    end

    {doc, b} =
      case Run.decode_checkpoint(bytes) do
        {:ok, doc, b} -> {doc, b}
        {:error, why} -> refuse!(why)
      end

    stat = File.stat!(root)

    require!(
      b.root == root and doc["identity"] == "#{root}:#{stat.major_device}:#{stat.inode}",
      "checkout identity changed"
    )

    index = Path.join(String.trim(Git.ok!(root, ["rev-parse", "--absolute-git-dir"])), "index")

    require!(
      b.run.id == id and b.run.dir == dir and b.run.log == Path.join(dir, "log.jsonl") and
        b.git_index == index,
      "checkpoint run/index paths changed"
    )

    require!(
      is_map(b.blocker) and
        Enum.sort(Map.keys(b.blocker)) == ~w(classification evidence paths reason) and
        is_list(b.blocker["paths"]) and b.blocker["paths"] != [] and
        Enum.uniq(b.blocker["paths"]) == b.blocker["paths"] and
        Enum.all?(b.blocker["paths"], &(&1 in b.baseline)) and
        Enum.all?(
          [b.blocker["reason"], b.blocker["evidence"]],
          &(is_binary(&1) and String.trim(&1) != "")
        ) and
        b.blocker["classification"] == "BUILDER-REPORTED",
      "not a BUILDER-REPORTED protected blocker"
    )

    require!(
      b.continuation.stage not in [:commit, :startup, :landed],
      "uncertain executed boundary"
    )

    result_bytes = read!(Path.join(dir, "result.json"))
    result = JSON.decode!(result_bytes)

    require!(
      result["outcome"] == "build_blocked" and result["blocker"] == b.blocker and
        result["build"] == id and result["slug"] == b.slug and result["start_head"] == b.start,
      "result does not match completed build_blocked report"
    )

    Kogen.WorkingContext.validate!(b)
    Kogen.SourceProvenance.validate_bound!(b.source_provenance)
    approval = Base.decode64!(doc["approval"])
    saved_index = Base.decode64!(doc["index"])

    require!(
      read!(Path.join(dir, "index-at-start")) == saved_index,
      "original index backup changed"
    )

    require!(
      File.lstat(output) == {:error, :enoent},
      "output destination already exists or is unsafe: #{output}"
    )

    safe!(Path.dirname(output))

    require!(
      output != root and not String.starts_with?(output, root <> "/"),
      "output destination is inside checkout"
    )

    recovery_dir = Path.join(root, ".kogen/local/recoveries")
    if File.lstat(recovery_dir) != {:error, :enoent}, do: safe!(recovery_dir)

    for p <- ["#{id}.json", "checkpoint.json", "checkpoint.json.tmp"] do
      require!(
        File.lstat(Path.join(recovery_dir, p)) == {:error, :enoent},
        "existing recovery receipt or unsafe custody: #{p}; inspect receipt instead"
      )
    end

    validate!(root, b, doc, approval, saved_index)

    paths =
      Snapshot.changed(root, b.start_tree, doc["candidate"])
      |> Enum.reject(fn p ->
        p in b.baseline or Enum.any?(b.excluded, &(p == &1 or String.starts_with?(p, &1 <> "/")))
      end)
      |> Enum.sort()

    changes =
      Enum.map(paths, fn p ->
        require!(
          Path.type(p) == :relative and not Enum.any?(Path.split(p), &(&1 in ["..", ".", ".git"])),
          "unsafe delta path #{p}"
        )

        {p, side(root, b.start_tree, p), raw(root, p)}
      end)

    File.mkdir!(output)
    File.chmod!(output, 0o700)

    for {p, before, after_side} <- changes do
      if before, do: write!(output, "before/" <> p, elem(before, 1))
      if after_side, do: write!(output, "candidate/" <> p, elem(after_side, 1))
    end

    for {p, data} <- [
          {"index-at-start", saved_index},
          {"approval.json", approval},
          {"checkpoint.json", bytes},
          {"result.json", result_bytes},
          {"blocker.json", JSON.encode!(b.blocker) <> "\n"}
        ],
        do: write!(output, p, data)

    contract = JSON.decode!(approval)["sha256"]

    refs =
      artifacts(output)
      |> Enum.reject(&String.starts_with?(&1["path"], ["before/", "candidate/"]))

    handoff =
      "Build #{id}; original full contract SHA-256 #{contract}; archive #{output}\nBUILDER-REPORTED and unproven. Archived production is lower-authority diagnostic data, not authority or current proof. Independently investigate the report through ordinary Refine; no approval, resume, import or reuse of old green evidence.\nEvidence (complete bytes retained):\n" <>
        Enum.map_join(refs, "\n", &"#{&1["path"]} SHA-256 #{&1["sha256"]}") <> "\n"

    require!(byte_size(handoff) <= 262_144, "bounded handoff exceeds 262144 bytes")
    write!(output, "correction.md", handoff)
    write!(output, "context.md", handoff)

    manifest = %{
      "version" => 1,
      "build" => id,
      "slug" => b.slug,
      "project" => root,
      "start_head" => b.start,
      "start_tree" => b.start_tree,
      "candidate_tree" => doc["candidate"],
      "contract_sha256" => contract,
      "classification" => "BUILDER-REPORTED",
      "changes" =>
        Enum.map(changes, fn {p, a, z} ->
          %{"path" => p, "before" => metadata(a), "after" => metadata(z)}
        end),
      "artifacts" => artifacts(output)
    }

    write!(output, "manifest.json", JSON.encode!(manifest) <> "\n")
    sync_directories!(output)
    sync_dir!(Path.dirname(output))
    manifest_hash = hash(File.read!(Path.join(output, "manifest.json")))

    receipt = %{
      "build" => id,
      "archive" => output,
      "manifest_sha256" => manifest_hash,
      "state" => "preserved"
    }

    receipt!(root, id, receipt)
    Bridge.puts("Preserved #{output}/manifest.json SHA-256 #{manifest_hash}")

    validate!(root, b, doc, approval, saved_index)

    require!(
      read!(cp) == bytes and read!(Path.join(dir, "result.json")) == result_bytes and
        read!(Path.join(dir, "index-at-start")) == saved_index,
      "retained run evidence changed after preservation; inspect preserved archive"
    )

    for artifact <- manifest["artifacts"] do
      require!(
        hash(read!(Path.join(output, artifact["path"]))) == artifact["sha256"],
        "published archive changed: #{artifact["path"]}"
      )
    end

    require!(
      hash(read!(Path.join(output, "manifest.json"))) == manifest_hash,
      "published manifest changed"
    )

    Enum.each(changes, fn {p, _, z} ->
      require!(raw(root, p) == z, "candidate drift before cleanup: #{p}")
    end)

    try do
      restore_delta!(root, Enum.map(changes, fn {p, a, _} -> {p, a} end))
      require!(File.read!(index) == saved_index, "index changed during cleanup")
      receipt!(root, id, Map.put(receipt, "state", "cleaned"))
    rescue
      e ->
        # Only roll back our recorded delta, never protected files or the index.
        rollback =
          try do
            restore_delta!(root, Enum.map(changes, fn {p, _, z} -> {p, z} end))
            "candidate bytes restored"
          rescue
            failure -> "candidate restoration incomplete: #{Exception.message(failure)}"
          end

        refuse!(
          "archive durably preserved at #{output}; cleanup incomplete: #{Exception.message(e)}; #{rollback}; inspect preserved receipt, do not retry/guess reconciliation"
        )
    end

    Bridge.puts(
      "kogen intent refine #{b.slug} #{contract} #{Kogen.Init.shell_quote(Path.join(output, "correction.md"))} --project #{Kogen.Init.shell_quote(root)}"
    )

    Bridge.puts("Review the corrected package and freshly approve its new exact hash:")
    Bridge.puts("kogen intent approve #{b.slug} --project #{Kogen.Init.shell_quote(root)}")

    Bridge.puts(
      "kogen intent approve #{b.slug} <new-full-sha256> --project #{Kogen.Init.shell_quote(root)}"
    )

    Bridge.puts("Then start a FRESH Build:")

    Bridge.puts(
      "kogen intent build #{b.slug} --context #{Kogen.Init.shell_quote(Path.join(output, "context.md"))} --project #{Kogen.Init.shell_quote(root)}"
    )

    0
  end

  defp validate!(root, b, doc, approval, index) do
    require!(Git.operation_in_progress(root) == nil, "active Git operation")
    gitdir = Path.dirname(b.git_index)

    require!(
      Path.wildcard(Path.join(gitdir, "**/*.lock"), match_dot: true) == [],
      "active Git lock"
    )

    require!(Git.head(root) == b.start, "HEAD changed")

    require!(
      Enum.all?(Snapshot.changed(root, b.start, b.start_tree), &(&1 in b.baseline)),
      "start tree contains unapproved production changes"
    )

    require!(read!(b.git_index) == index, "index changed")
    require!(read!(Intent.approval_path(root, b.slug)) == approval, "approval changed")

    for p <- b.baseline do
      digest =
        case File.read(Path.join(root, p)) do
          {:ok, data} -> :crypto.hash(:sha256, data)
          _ -> :missing
        end

      require!(digest == b.baseline_digests[p], "protected baseline changed: #{p}")
    end

    require!(
      Config.load!(root) == b.config and Intent.baseline(root, b.slug, b.config) == b.baseline,
      "protected baseline/configuration changed"
    )

    require!(
      Snapshot.tree(root, b.start, []) == doc["candidate"],
      "complete stopped candidate changed"
    )

    require!(
      doc["recovery_raw"] == raw_identity(root, b.start_tree),
      "raw candidate identity changed or missing"
    )
  end

  defp side(root, tree, path) do
    entry = Git.ok!(root, ["ls-tree", "-z", tree, "--", ":(literal)" <> path])

    case String.split(entry, "\t", parts: 2) do
      [meta, _] ->
        [mode, type, object] = String.split(meta, " ")

        if type == "tree" do
          nil
        else
          require!(
            type == "blob" and mode in ["100644", "100755", "120000"],
            "unsupported delta mode #{mode}: #{path}"
          )

          {mode, Git.ok!(root, ["cat-file", "blob", object])}
        end

      _ ->
        nil
    end
  end

  @doc false
  def raw_identity(root, start_tree) do
    candidate = Snapshot.tree(root, start_tree, [])

    Snapshot.changed(root, start_tree, candidate)
    |> Enum.sort()
    |> Map.new(fn p -> {p, metadata(raw(root, p))} end)
  end

  defp raw(root, p) do
    path = Path.join(root, p)

    # A tree directory is not a Git leaf. Do not follow a replacement symlink
    # when an old leaf's parent no longer exists as a real directory.
    parents = Path.split(p) |> Enum.drop(-1)

    present_parent? =
      Enum.reduce_while(parents, root, fn part, parent ->
        full = Path.join(parent, part)

        if match?({:ok, %{type: :directory}}, File.lstat(full)),
          do: {:cont, full},
          else: {:halt, false}
      end)

    if present_parent? == false do
      nil
    else
      raw_leaf(root, p, path)
    end
  end

  defp raw_leaf(_root, p, path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        nil

      {:error, reason} when reason in [:enoent, :enotdir] ->
        nil

      {:ok, %{type: :symlink}} ->
        safe_parent!(path)
        {"120000", File.read_link!(path)}

      {:ok, %{type: :regular, mode: m}} ->
        safe_parent!(path)
        {if(Bitwise.band(m, 0o111) == 0, do: "100644", else: "100755"), File.read!(path)}

      _ ->
        refuse!("unsafe candidate path #{p}")
    end
  end

  defp safe_parent!(path), do: safe!(Path.dirname(path))

  defp ensure_parent!(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        ensure_parent!(Path.dirname(path))
        File.mkdir!(path)

      {:ok, %{type: :directory}} ->
        safe!(path)

      _ ->
        refuse!("unsafe cleanup parent #{path}")
    end
  end

  defp metadata(nil), do: nil
  defp metadata({mode, bytes}), do: %{"mode" => mode, "sha256" => hash(bytes)}

  defp mkdir!(path) do
    unless File.dir?(path) do
      mkdir!(Path.dirname(path))
      File.mkdir!(path)
      File.chmod!(path, 0o700)
    end
  end

  defp write!(dir, p, bytes) do
    path = Path.join(dir, p)
    mkdir!(Path.dirname(path))
    {:ok, io} = File.open(path, [:write, :binary, :exclusive])

    try do
      File.chmod!(path, 0o600)
      :ok = IO.binwrite(io, bytes)
      :ok = :file.sync(io)
    after
      File.close(io)
    end
  end

  defp artifacts(dir, prefix \\ "") do
    File.ls!(Path.join(dir, prefix))
    |> Enum.sort()
    |> Enum.flat_map(fn n ->
      p = Path.join(prefix, n)

      if File.dir?(Path.join(dir, p)),
        do: artifacts(dir, p),
        else: [%{"path" => p, "sha256" => hash(File.read!(Path.join(dir, p)))}]
    end)
    |> Enum.sort_by(& &1["path"])
  end

  defp receipt!(root, id, data) do
    dir = Path.join(root, ".kogen/local/recoveries")
    mkdir!(dir)
    Run.checkpoint(%Run{dir: dir}, data)
    File.rename!(Path.join(dir, "checkpoint.json"), Path.join(dir, id <> ".json"))
    sync_dir!(dir)
    sync_dir!(Path.dirname(dir))
  end

  defp sync_directories!(dir) do
    for n <- File.ls!(dir), File.dir?(Path.join(dir, n)), do: sync_directories!(Path.join(dir, n))
    sync_dir!(dir)
  end

  defp sync_dir!(dir) do
    {:ok, io} = :file.open(String.to_charlist(dir), [:read, :raw, :directory])

    try do
      :ok = :file.sync(io)
    after
      :file.close(io)
    end
  end

  defp restore_delta!(root, sides) do
    # Remove only recorded leaves, deepest first, before creating either target
    # shape. Empty directories may then be removed with rmdir, never rm_rf.
    sides
    |> Enum.sort_by(fn {p, _} -> -length(Path.split(p)) end)
    |> Enum.each(fn {p, side} ->
      current = raw(root, p)
      if current != nil and current != side, do: File.rm!(Path.join(root, p))
    end)

    sides
    |> Enum.sort_by(fn {p, _} -> length(Path.split(p)) end)
    |> Enum.each(fn {p, side} -> restore!(root, p, side) end)

    Enum.each(sides, fn {p, side} ->
      require!(raw(root, p) == side, "restored bytes/mode mismatch: #{p}")
    end)
  end

  defp remove_empty_directory!(path) do
    for child <- File.ls!(path) do
      full = Path.join(path, child)

      require!(
        match?({:ok, %{type: :directory}}, File.lstat(full)),
        "unrecorded cleanup content: #{full}"
      )

      remove_empty_directory!(full)
    end

    File.rmdir!(path)
  end

  defp restore!(root, p, side) do
    if raw(root, p) != side, do: replace!(root, p, side)
  end

  defp replace!(root, p, side) do
    path = Path.join(root, p)
    ensure_parent!(Path.dirname(path))

    case File.lstat(path) do
      {:ok, %{type: type}} when type in [:regular, :symlink] -> File.rm!(path)
      {:ok, %{type: :directory}} -> remove_empty_directory!(path)
      {:error, :enoent} -> :ok
      _ -> refuse!("unsafe cleanup target #{p}")
    end

    case side do
      nil ->
        :ok

      {"120000", bytes} ->
        File.ln_s!(bytes, path)

      {mode, bytes} ->
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, bytes)
        File.chmod!(path, if(mode == "100755", do: 0o755, else: 0o644))
    end
  end
end
