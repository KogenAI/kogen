Code.require_file("../support/test_reliability_catalog.ex", __DIR__)

defmodule Kogen.WholeSuiteRemediationTest do
  use ExUnit.Case, async: true

  alias Kogen.TestReliabilityCatalog, as: Catalog

  test "claimed repairs are Candidate blobs and both narrow prior Candidates are rejected" do
    root = Path.expand("../..", __DIR__)
    catalog = Catalog.load!(Path.join(root, "priv/kogen/test-reliability.yaml"))
    changed = changed_paths(root, catalog)

    assert :ok = Catalog.validate(catalog, root, changed)

    five_file_candidate =
      ~w(scripts/check/offline.py test/support/isolated_case.ex test/support/isolated_process.py test/kogen/isolation_test.exs test/kogen/isolation_cleanup_test.exs)

    assert {:error, errors} = Catalog.validate(catalog, root, five_file_candidate)
    assert Enum.any?(errors, &String.contains?(&1, "implementation is unchanged"))

    all_keep =
      update_in(
        catalog["declarations"],
        &Enum.map(&1, fn row -> Map.put(row, "disposition", "keep") end)
      )

    assert {:error, errors} = Catalog.validate(all_keep, root, changed)
    assert "blanket keep is forbidden" in errors
  end

  defp changed_paths(root, catalog) do
    case System.cmd("git", ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
           cd: root,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        output
        |> String.split("\0", trim: true)
        |> Enum.map(fn entry ->
          entry |> String.slice(3..-1//1) |> String.split(" -> ") |> List.last()
        end)

      {_output, _status} ->
        catalog["declarations"]
        |> Enum.flat_map(&[&1["implementation"], &1["preservation_control"]])
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
    end
  end
end
