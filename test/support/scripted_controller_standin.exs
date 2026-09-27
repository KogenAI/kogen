# Separate-OS-process controller stand-in for build-reconcile tests.
#
# This intentionally runs through `elixir` with the test VM's already compiled
# code paths. `mix run` would compile the project into an IsolatedCase's empty
# private _build before the fixture can start.

Code.require_file(Path.join(__DIR__, "scripted_build_fixture.ex"))

case System.argv() do
  [dir, encoded_opts] ->
    opts =
      encoded_opts
      |> Jason.decode!()
      |> Enum.map(fn {key, value} -> {String.to_atom(key), value} end)

    Kogen.ScriptedBuildFixture.run(dir, opts)

  args ->
    raise "usage: scripted_controller_standin.exs <control> <options-json>, got #{inspect(args)}"
end
