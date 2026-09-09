defmodule Kogen.BoundaryNegativeControlTest do
  @moduledoc """
  INTENT.md: "Boundary checks through the enabled compiler ... with one real
  forbidden dependency test as negative control ... The negative-control
  test compiles a throwaway module that violates this and asserts the
  Boundary error."

  This builds a tiny, disposable fixture Mix project under a temp dir, with
  its own `mix.exs` declaring `{:boundary, path: <this project's
  deps/boundary>}` (a path dependency, so no network access is required: it
  reuses the already-fetched, already-hex-installed copy of the package).
  The fixture defines two minimal boundary modules mirroring the real
  shape (`use Boundary, deps: []`), where `B` calls a function on `A`
  without declaring `A` as a dependency. Real `mix compile
  --warnings-as-errors --force`, run as a subprocess against the fixture
  directory, is asserted to fail with the Boundary compiler's own
  "forbidden reference" wording -- proving the compiler (not merely the
  application code) actually enforces `Kogen.Git`/`Kogen.Check` not
  depending on `Kogen.Harness`.
  """
  use ExUnit.Case, async: true

  @moduletag timeout: 120_000

  test "the Boundary compiler rejects an undeclared cross-boundary reference" do
    boundary_path = Path.expand("deps/boundary", File.cwd!())
    assert File.dir?(boundary_path), "expected #{boundary_path} to exist (already-fetched dep)"

    fixture_dir =
      Path.join(
        System.tmp_dir!(),
        "kogen-boundary-fixture-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(fixture_dir) end)

    write_fixture!(fixture_dir, boundary_path)

    # First confirm (without --warnings-as-errors) that the compiler emits
    # the forbidden-reference warning at all, independent of whether the
    # installed Elixir/boundary version treats it as fatal by default.
    {plain_output, _plain_exit} =
      System.cmd("mix", ["compile"],
        cd: fixture_dir,
        env: [
          {"MIX_BUILD_PATH", Path.join(fixture_dir, "_build")},
          {"ERL_FLAGS", "+S 2:2 +SDcpu 1 +SDio 1"}
        ],
        stderr_to_stdout: true
      )

    assert plain_output =~ "forbidden reference to A",
           "expected a plain `mix compile` to report the forbidden reference; got:\n#{plain_output}"

    # Now assert the compiler actually fails the build over it.
    {output, exit_code} =
      System.cmd("mix", ["compile", "--warnings-as-errors", "--force"],
        cd: fixture_dir,
        env: [
          {"MIX_BUILD_PATH", Path.join(fixture_dir, "_build")},
          {"ERL_FLAGS", "+S 2:2 +SDcpu 1 +SDio 1"}
        ],
        stderr_to_stdout: true
      )

    assert exit_code != 0,
           "expected `mix compile --warnings-as-errors` to fail on a forbidden boundary reference; got:\n#{output}"

    assert output =~ "forbidden reference to A"
    assert output =~ "references from B to A are not allowed"
  end

  defp write_fixture!(fixture_dir, boundary_path) do
    File.mkdir_p!(Path.join(fixture_dir, "lib"))

    File.write!(Path.join(fixture_dir, "mix.exs"), mix_exs(boundary_path))
    File.write!(Path.join(fixture_dir, "lib/a.ex"), module_a())
    File.write!(Path.join(fixture_dir, "lib/b.ex"), module_b())
  end

  defp mix_exs(boundary_path) do
    """
    defmodule BoundaryFixture.MixProject do
      use Mix.Project

      def project do
        [
          app: :boundary_fixture,
          version: "0.1.0",
          elixir: "~> 1.20",
          compilers: [:boundary] ++ Mix.compilers(),
          boundary: [default: [check: [apps: [{:mix, :runtime}]]]],
          deps: deps()
        ]
      end

      def application, do: [extra_applications: [:logger]]

      defp deps do
        [{:boundary, path: #{inspect(boundary_path)}, runtime: false}]
      end
    end
    """
  end

  defp module_a do
    """
    defmodule A do
      use Boundary, deps: []

      def foo, do: :ok
    end
    """
  end

  defp module_b do
    """
    defmodule B do
      use Boundary, deps: []

      def bar, do: A.foo()
    end
    """
  end
end
