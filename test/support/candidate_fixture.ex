defmodule Kogen.CandidateFixture do
  @moduledoc """
  Reads what a fixture Build left behind for a control checkout: its tracking
  records (always in control), each record's `candidate` and `boundary`
  blocks, the harness home, the fake roles' scratch state (kept in the
  harness home, since publication removes the Candidate worktree) and the
  per-launch receipts the fake roles write from inside each launched process.
  """

  @doc "Creates the control `deps/` Build admission copies into each Candidate."
  def deps!(control), do: File.mkdir_p!(Path.join(control, "deps"))

  @doc "Every tracking record under `control`, least recently written first."
  def records(control) do
    control
    |> Path.join(".kogen/runtime/scenario-tracking/*/record.json")
    |> Path.wildcard()
    |> Enum.map(&{&1, File.read!(&1) |> Jason.decode!()})
    |> Enum.sort_by(fn {path, _record} -> modified(path) end)
    |> Enum.map(&elem(&1, 1))
  end

  # Sub-second modification time, so two Builds in one second still order.
  defp modified(path) do
    {out, 0} = System.cmd("/usr/bin/stat", ["-f", "%Fm", path])
    out |> String.trim() |> Float.parse() |> elem(0)
  end

  @doc "The latest tracking record under `control`."
  def record(control), do: List.last(records(control))

  @doc "The latest record's `candidate` block."
  def candidate(control), do: control |> record() |> Map.fetch!("candidate")

  @doc "The latest Build's harness home."
  def harness_home(control), do: candidate(control)["harness_home"]

  @doc "The latest Build's Candidate worktree path."
  def worktree(control), do: candidate(control)["worktree_path"]

  @doc "The fake roles' scratch state directory of the latest Build."
  def fake_state(control), do: Path.join(harness_home(control), "fake-state")

  @doc "A file in the latest Build's fake scratch state."
  def fake_state(control, name), do: Path.join(fake_state(control), name)

  @doc "Every launch receipt of the latest Build (or of `home`), oldest first."
  def receipts(control_or_home, opts \\ []) do
    home =
      if Keyword.get(opts, :home, false), do: control_or_home, else: harness_home(control_or_home)

    home
    |> Path.join("launch-receipts/*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&(File.read!(&1) |> Jason.decode!()))
  end

  @doc ~S|Launch receipts of `role` ("developer", "reviewer" or "" for readiness).|
  def receipts(control, role, opts) do
    control |> receipts(opts) |> Enum.filter(&(&1["role"] == role))
  end

  @doc "The Candidate worktrees registered in `control`'s `git worktree list`."
  def registered_worktrees(control) do
    {listing, 0} = System.cmd("git", ["worktree", "list", "--porcelain"], cd: control)

    listing
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn
      "worktree " <> path -> [path]
      _ -> []
    end)
  end
end
