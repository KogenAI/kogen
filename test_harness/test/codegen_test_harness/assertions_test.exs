defmodule CodegenTestHarness.AssertionsTest do
  use ExUnit.Case, async: true

  alias CodegenTestHarness.Assertions

  defp tmp_dir do
    dir = System.tmp_dir!() |> Path.join("assertions_test_#{:rand.uniform(999_999)}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  describe "assert_built_html_non_blank!/2" do
    test "passes when html contains a hashed bundle script src" do
      dir = tmp_dir()
      File.mkdir_p!(Path.join(dir, "public"))

      File.write!(Path.join([dir, "public", "index.html"]), """
      <!doctype html>
      <html><head>
        <script type="module" src="/assets/index-DqBSCfED.js"></script>
      </head><body><div id="app"></div></body></html>
      """)

      assert Assertions.assert_built_html_non_blank!(dir, "public/index.html") == :ok
    end

    test "raises when html has no bundle script (bare SPA shell)" do
      dir = tmp_dir()
      File.mkdir_p!(Path.join(dir, "public"))

      File.write!(Path.join([dir, "public", "index.html"]), """
      <!doctype html>
      <html><head></head><body><div id="app"></div></body></html>
      """)

      assert_raise ExUnit.AssertionError, fn ->
        Assertions.assert_built_html_non_blank!(dir, "public/index.html")
      end
    end
  end

  describe "assert_assets_deploy!/1" do
    test "returns :ok and skips mix call when no assets/ dir present" do
      dir = tmp_dir()

      File.write!(Path.join(dir, "mix.exs"), """
      defmodule A.MixProject do
        use Mix.Project
        def project, do: [app: :a, version: "0.1.0"]
      end
      """)

      assert Assertions.assert_assets_deploy!(dir) == :ok
    end
  end

  describe "assert_usage_rules_index_no_dangling_citations!/1" do
    test "passes when every cited file exists on disk" do
      dir = tmp_dir()
      usage_rules_dir = Path.join(dir, "codegen/usage_rules")
      File.mkdir_p!(usage_rules_dir)

      File.write!(Path.join(usage_rules_dir, "phoenix-1.8.8.md"), "# phoenix")

      File.write!(Path.join(usage_rules_dir, "INDEX.md"), """
      # Usage Rules Index

      ## phoenix

      Use when: writing controllers.

      - `phoenix-1.8.8.md`
      """)

      assert Assertions.assert_usage_rules_index_no_dangling_citations!(dir) == :ok
    end

    test "raises when a cited file does not exist" do
      dir = tmp_dir()
      usage_rules_dir = Path.join(dir, "codegen/usage_rules")
      File.mkdir_p!(usage_rules_dir)

      File.write!(Path.join(usage_rules_dir, "INDEX.md"), """
      # Usage Rules Index

      ## phoenix

      Use when: writing controllers.

      - `phoenix-1.8.4.md`
      """)

      assert_raise ExUnit.AssertionError, fn ->
        Assertions.assert_usage_rules_index_no_dangling_citations!(dir)
      end
    end

    test "raises when INDEX.md itself is missing" do
      dir = tmp_dir()
      File.mkdir_p!(Path.join(dir, "codegen/usage_rules"))

      assert_raise ExUnit.AssertionError, fn ->
        Assertions.assert_usage_rules_index_no_dangling_citations!(dir)
      end
    end
  end
end
