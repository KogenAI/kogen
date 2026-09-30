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

  test "final catalog is exhaustive, resolved, and declaration-specific; name binding is advisory",
       context do
    assert context.catalog["declaration_count"] == length(context.catalog["declarations"])
    assert context.catalog["provisional_count"] == 0
    refute Enum.any?(context.catalog["declarations"], &Map.has_key?(&1, "source_sha256"))
    assert :ok = Catalog.validate(context.catalog, context.root)
    assert :ok = Catalog.validate_remediation(context.catalog, context.remediation)
    assert is_list(Catalog.advisories(context.catalog, context.root))

    [first | rest] = context.remediation["resolved"]

    drifted =
      put_in(context.remediation, ["resolved"], [Map.put(first, "scenario", "foreign") | rest])

    assert {:error, ["remediation rows differ from catalog"]} =
             Catalog.validate_remediation(context.catalog, drifted)
  end

  test "validator rejects blanket keep, copied controls, malformed rows and aliased roles; stale names only advise",
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

    stale_witness =
      put_in(context.catalog, ["declarations"], [
        Map.put(first, "consumer_witness", "definitely absent consumer symbol") | [second | rest]
      ])

    assert :ok = Catalog.validate(stale_witness, context.root)

    assert Enum.any?(
             Catalog.advisories(stale_witness, context.root),
             &String.contains?(&1, "consumer does not expose claimed behavior")
           )

    renamed =
      put_in(context.catalog, ["declarations"], [
        Map.put(first, "declaration", "a declaration that no test carries") | [second | rest]
      ])

    assert :ok = Catalog.validate(renamed, context.root)

    assert Enum.any?(
             Catalog.advisories(renamed, context.root),
             &(String.contains?(&1, first["id"]) and
                 String.contains?(&1, first["file"]) and
                 String.contains?(&1, "a declaration that no test carries"))
           )

    deleted_file =
      put_in(context.catalog, ["declarations"], [
        Map.put(first, "file", "test/kogen/no_such_file_test.exs") | [second | rest]
      ])

    assert {:error, errors} = Catalog.validate(deleted_file, context.root)
    assert errors == ["maintained source inventory is contradictory"]

    malformed =
      put_in(context.catalog, ["declarations"], [
        Map.delete(first, "wrong_control") | [second | rest]
      ])

    assert {:error, errors} = Catalog.validate(malformed, context.root)
    assert Enum.any?(errors, &String.contains?(&1, "missing wrong_control"))

    bad_disposition =
      put_in(context.catalog, ["declarations"], [
        Map.put(first, "disposition", "obliterate") | [second | rest]
      ])

    assert {:error, errors} = Catalog.validate(bad_disposition, context.root)
    assert Enum.any?(errors, &String.contains?(&1, "invalid disposition"))

    unsafe =
      put_in(context.catalog, ["declarations"], [
        Map.put(first, "implementation", "../outside.ex") | [second | rest]
      ])

    assert {:error, errors} = Catalog.validate(unsafe, context.root)
    assert Enum.any?(errors, &String.contains?(&1, "evidence path is unsafe"))

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

    test "a renamed test is not a failure and is only advised", %{
      base: base,
      catalog: catalog,
      exs_path: exs_path
    } do
      assert [] = Catalog.advisories(catalog, base)

      File.write!(
        exs_path,
        String.replace(
          File.read!(exs_path),
          "carries the declared apostrophe'd behavior",
          "renamed away"
        )
      )

      assert :ok = Catalog.validate(catalog, base)
      assert [advisory] = Catalog.advisories(catalog, base)
      assert advisory =~ "fixture:t001"
      assert advisory =~ "missing declaration"
    end

    test "an added test is not a failure", %{base: base, catalog: catalog, exs_path: exs_path} do
      File.write!(
        exs_path,
        String.replace(
          File.read!(exs_path),
          "end\n",
          "  test \"a brand new test\" do\n    assert true\n  end\nend\n"
        )
      )

      assert :ok = Catalog.validate(catalog, base)
      assert [] = Catalog.advisories(catalog, base)
    end

    test "a deleted test file is not a failure and is only advised", %{
      base: base,
      catalog: catalog,
      exs_path: exs_path
    } do
      File.rm!(exs_path)
      assert :ok = Catalog.validate(catalog, base)
      assert Enum.any?(Catalog.advisories(catalog, base), &String.contains?(&1, "fixture:t001"))
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

    test "a stale consumer witness only advises; a blank one is malformed", %{
      base: base,
      catalog: catalog
    } do
      [exs_row, python_row] = catalog["declarations"]

      stale =
        put_in(catalog, ["declarations"], [
          Map.put(exs_row, "consumer_witness", "definitely absent text"),
          python_row
        ])

      assert :ok = Catalog.validate(stale, base)

      assert Enum.any?(
               Catalog.advisories(stale, base),
               &String.contains?(&1, "consumer does not expose")
             )

      blank =
        put_in(catalog, ["declarations"], [Map.put(exs_row, "consumer_witness", " "), python_row])

      assert {:error, errors} = Catalog.validate(blank, base)
      assert Enum.any?(errors, &String.contains?(&1, "missing consumer_witness"))
    end
  end
end
