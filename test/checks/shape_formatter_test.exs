defmodule Kogen.Checks.ShapeFormatterTest do
  use Kogen.Testkit.Case

  alias Kogen.Checks.ShapeFormatRequest

  test "derives the formatter argv from a check that verifies formatting", %{tmp_dir: root} do
    formatter_script = Path.join(root, "formatter.sh")
    calls_path = Path.join(root, "formatter-calls.txt")
    relative = ".kogen/acceptance/shape_test.exs"

    File.write!(formatter_script, ~s(printf '%s\\n' "$@" > "$KOGEN_FORMAT_CALLS"\n))
    File.mkdir_p!(Path.dirname(Path.join(root, relative)))
    File.write!(Path.join(root, relative), "defmodule ShapeTest do\nend\n")

    write_config(root, """
    name: tiny-app
    checks:
      - name: formatting
        argv: ["/bin/sh", #{inspect(formatter_script)}, format, --check-formatted]
        timeout_ms: 1000
    """)

    assert {:ok, project} = Kogen.Project.load(root)

    assert :ok =
             Kogen.Checks.format_shape_files(%ShapeFormatRequest{
               workdir: root,
               slug: "shape",
               written_paths: [relative],
               project: project,
               run_dir: Path.join(root, "shape-run"),
               env: %{"KOGEN_FORMAT_CALLS" => calls_path}
             })

    assert File.read!(calls_path) == "format\n#{relative}\n"
  end

  defp write_config(root, source) do
    config = Path.join([root, ".kogen", "project.yaml"])
    File.mkdir_p!(Path.dirname(config))
    File.write!(config, source)
  end
end
