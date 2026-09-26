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

  test "final catalog is exhaustive, resolved, declaration-bound, and declaration-specific",
       context do
    assert context.catalog["declaration_count"] == length(context.catalog["declarations"])
    assert context.catalog["provisional_count"] == 0
    refute Enum.any?(context.catalog["declarations"], &Map.has_key?(&1, "source_sha256"))
    assert :ok = Catalog.validate(context.catalog, context.root)
    assert :ok = Catalog.validate_remediation(context.catalog, context.remediation)

    [first | rest] = context.remediation["resolved"]

    drifted =
      put_in(context.remediation, ["resolved"], [Map.put(first, "scenario", "foreign") | rest])

    assert {:error, ["remediation rows differ from catalog"]} =
             Catalog.validate_remediation(context.catalog, drifted)
  end

  test "validator rejects blanket keep, copied controls, filename consumers, unresolved declarations, and aliased roles",
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

    renamed =
      put_in(context.catalog, ["declarations"], [
        Map.put(first, "declaration", "a declaration that no test carries") | [second | rest]
      ])

    assert {:error, errors} = Catalog.validate(renamed, context.root)

    assert Enum.any?(
             errors,
             &(String.contains?(&1, first["id"]) and
                 String.contains?(&1, first["file"]) and
                 String.contains?(&1, "a declaration that no test carries"))
           )

    deleted_file =
      put_in(context.catalog, ["declarations"], [
        Map.put(first, "file", "test/kogen/no_such_file_test.exs") | [second | rest]
      ])

    assert {:error, errors} = Catalog.validate(deleted_file, context.root)
    assert Enum.any?(errors, &String.contains?(&1, first["id"]))

    aliased =
      put_in(context.catalog, ["declarations"], [
        Map.put(first, "wrong_control", first["positive_control"]) | [second | rest]
      ])

    assert {:error, errors} = Catalog.validate(aliased, context.root)
    assert Enum.any?(errors, &String.contains?(&1, "evidence roles alias one path"))
  end

  describe "name binding on a fixture catalog" do
    setup do
      base =
        Path.join(
          System.tmp_dir!(),
          "test-reliability-fixture-#{System.unique_integer([:positive])}"
        )

      exs_path = Path.join(base, "test/kogen/fixture_test.exs")
      py_path = Path.join(base, "test/support/fixture_test.py")
      recovery_path = Path.join(base, "test/support/fixture_recovery.txt")
      implementation_path = Path.join(base, "test/support/fixture_implementation.txt")
      File.mkdir_p!(Path.dirname(exs_path))
      File.mkdir_p!(Path.dirname(py_path))

      File.write!(exs_path, """
      defmodule Kogen.FixtureTest do
        use ExUnit.Case

        test "carries the declared apostrophe'd behavior" do
          assert true
        end
      end
      """)

      File.write!(py_path, """
      def test_carries_the_declared_python_behavior():
          assert True
      """)

      File.write!(recovery_path, "recovery fixture\n")
      File.write!(implementation_path, "implementation fixture\n")

      on_exit(fn -> File.rm_rf!(base) end)

      row = fn overrides ->
        Map.merge(
          %{
            "id" => "fixture:t001",
            "file" => "test/kogen/fixture_test.exs",
            "declaration" => "carries the declared apostrophe'd behavior",
            "disposition" => "repair",
            "public_outcome" => "fixture:t001 outcome text that is long enough to be unique",
            "consumer" => "test/kogen/fixture_test.exs",
            "consumer_witness" => "defmodule Kogen.FixtureTest do",
            "positive_control" => "test/kogen/fixture_test.exs",
            "wrong_control" => "test/support/fixture_test.py",
            "wrong_control_locator" => "fixture:t001 rejects the wrong control variant uniquely",
            "failure_recovery" => "test/support/fixture_recovery.txt",
            "implementation" => "test/support/fixture_implementation.txt"
          },
          overrides
        )
      end

      python_row =
        row.(%{
          "id" => "fixture:t002",
          "file" => "test/support/fixture_test.py",
          "declaration" => "test_carries_the_declared_python_behavior",
          "public_outcome" => "fixture:t002 outcome text that is long enough to be unique too",
          "positive_control" => "test/support/fixture_test.py",
          "wrong_control" => "test/kogen/fixture_test.exs",
          "wrong_control_locator" => "fixture:t002 rejects the wrong control python variant",
          "failure_recovery" => "test/support/fixture_implementation.txt",
          "implementation" => "test/support/fixture_recovery.txt"
        })

      exs_row = row.(%{})

      catalog = %{
        "schema_version" => 1,
        "intent_id" => "fixture",
        "declaration_count" => 2,
        "provisional_count" => 0,
        "maintained_sources" => ["test/kogen/fixture_test.exs", "test/support/fixture_test.py"],
        "declarations" => [exs_row, python_row]
      }

      %{base: base, catalog: catalog, exs_path: exs_path}
    end

    test "a comment added to the catalogued file still passes", %{
      base: base,
      catalog: catalog,
      exs_path: exs_path
    } do
      File.write!(exs_path, "# a harmless comment\n" <> File.read!(exs_path))
      assert :ok = Catalog.validate(catalog, base)
    end

    test "a renamed test fails naming the row", %{
      base: base,
      catalog: catalog,
      exs_path: exs_path
    } do
      File.write!(
        exs_path,
        String.replace(
          File.read!(exs_path),
          "carries the declared apostrophe'd behavior",
          "renamed away"
        )
      )

      assert {:error, errors} = Catalog.validate(catalog, base)
      assert Enum.any?(errors, &String.contains?(&1, "fixture:t001"))
    end

    test "a deleted file fails", %{base: base, catalog: catalog, exs_path: exs_path} do
      File.rm!(exs_path)
      assert {:error, errors} = Catalog.validate(catalog, base)
      assert Enum.any?(errors, &String.contains?(&1, "fixture:t001"))
    end

    test "a Python row resolves by def", %{base: base, catalog: catalog} do
      assert :ok = Catalog.validate(catalog, base)
      [exs_row, python_row] = catalog["declarations"]
      assert python_row["file"] =~ ".py"
      assert exs_row["file"] =~ ".exs"
    end

    test "a declaration with an apostrophe resolves", %{base: base, catalog: catalog} do
      [exs_row | _] = catalog["declarations"]
      assert exs_row["declaration"] =~ "'"
      assert :ok = Catalog.validate(catalog, base)
    end

    test "a missing consumer witness still fails", %{base: base, catalog: catalog} do
      [exs_row, python_row] = catalog["declarations"]
      broken = Map.put(exs_row, "consumer_witness", "definitely absent text")
      catalog = put_in(catalog, ["declarations"], [broken, python_row])

      assert {:error, errors} = Catalog.validate(catalog, base)
      assert Enum.any?(errors, &String.contains?(&1, "consumer does not expose claimed behavior"))
    end
  end
end
