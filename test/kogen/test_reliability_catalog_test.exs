Code.require_file("../support/test_reliability_catalog.ex", __DIR__)

defmodule Kogen.TestReliabilityCatalogTest do
  use ExUnit.Case, async: true

  alias Kogen.TestReliabilityCatalog, as: Catalog

  setup do
    root = Path.expand("../..", __DIR__)
    catalog = Catalog.load!(Path.join(root, "priv/kogen/test-reliability.yaml"))
    remediation = Catalog.load!(Path.join(root, "priv/kogen/test-reliability-remediation.yaml"))
    %{root: root, catalog: catalog, remediation: remediation}
  end

  test "final catalog is exhaustive, resolved, source-bound, and declaration-specific", context do
    assert context.catalog["declaration_count"] == 346
    assert context.catalog["provisional_count"] == 0
    assert :ok = Catalog.validate(context.catalog, context.root)
    assert :ok = Catalog.validate_remediation(context.catalog, context.remediation)

    [first | rest] = context.remediation["resolved"]

    drifted =
      put_in(context.remediation, ["resolved"], [Map.put(first, "scenario", "foreign") | rest])

    assert {:error, ["remediation rows differ from catalog"]} =
             Catalog.validate_remediation(context.catalog, drifted)
  end

  test "validator rejects blanket keep, copied controls, filename consumers, stale source, and aliased roles",
       context do
    [first, second | rest] = context.catalog["declarations"]

    all_keep =
      put_in(
        context.catalog,
        ["declarations"],
        Enum.map(context.catalog["declarations"], &Map.put(&1, "disposition", "keep"))
      )

    assert {:error, errors} = Catalog.validate(all_keep, context.root)
    assert "blanket keep is forbidden" in errors

    copied =
      put_in(context.catalog, ["declarations"], [
        first,
        Map.put(second, "wrong_control_locator", first["wrong_control_locator"]) | rest
      ])

    assert {:error, errors} = Catalog.validate(copied, context.root)
    assert "wrong controls must be declaration-specific" in errors

    guessed =
      put_in(context.catalog, ["declarations"], [
        Map.put(first, "consumer_witness", "definitely absent consumer symbol") | [second | rest]
      ])

    assert {:error, errors} = Catalog.validate(guessed, context.root)
    assert Enum.any?(errors, &String.contains?(&1, "consumer does not expose claimed behavior"))

    stale =
      put_in(context.catalog, ["declarations"], [
        Map.put(first, "source_sha256", String.duplicate("0", 64)) | [second | rest]
      ])

    assert {:error, errors} = Catalog.validate(stale, context.root)
    assert Enum.any?(errors, &String.contains?(&1, "source binding is stale"))

    aliased =
      put_in(context.catalog, ["declarations"], [
        Map.put(first, "wrong_control", first["positive_control"]) | [second | rest]
      ])

    assert {:error, errors} = Catalog.validate(aliased, context.root)
    assert Enum.any?(errors, &String.contains?(&1, "evidence roles alias one path"))
  end
end
