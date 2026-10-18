defmodule Kogen do
  @moduledoc "Kogen shapes, builds, verifies, reviews and commits one requested feature at a time."

  @doc "The caller's environment, working directory and installation root, as sent by `kogen`."
  def caller, do: :persistent_term.get(:kogen_caller)

  @doc "`kogen <sha8> (<date>)` or `kogen dev+<hash8> (<date>, uncommitted source)` (CLI-10), written at packaging."
  def version do
    Path.join(System.fetch_env!("RELEASE_ROOT"), "VERSION") |> File.read!() |> String.trim()
  end

  @doc "A path under the system temporary folder that no other Kogen process picks."
  def tmp_path(prefix),
    do:
      Path.join(
        System.tmp_dir!(),
        prefix <> "-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      )

  @doc "The testing rules Kogen gives the shaper, the builder and the reviewer (SET-6), as installed."
  def testing_rules,
    do: Path.join(caller().install_root, "docs/testing-rules.md") |> File.read!()
end
