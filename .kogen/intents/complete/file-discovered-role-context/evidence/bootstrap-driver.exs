Code.ensure_loaded!(Kogen.Build)
beam = Path.join([Mix.Project.build_path(), "lib/kogen/ebin/Elixir.Kogen.Build.beam"])
{:ok, {_, before_disk}} = :beam_lib.md5(String.to_charlist(beam))
before_memory = Kogen.Build.module_info(:md5)
result = Kogen.Build.run(System.fetch_env!("ROLE_CONTEXT_PROBE_SLUG"))
{:ok, {_, after_disk}} = :beam_lib.md5(String.to_charlist(beam))
report = %{
  result: inspect(result),
  before_disk: Base.encode16(before_disk),
  before_memory: Base.encode16(before_memory),
  after_memory: Base.encode16(Kogen.Build.module_info(:md5)),
  after_disk: Base.encode16(after_disk)
}
path = Path.join([System.fetch_env!("ROLE_CONTEXT_PROBE_RUN"), System.fetch_env!("ROLE_CONTEXT_PROBE_PHASE"), "engine-identity.json"])
File.write!(path, Jason.encode!(report, pretty: true))
IO.puts(Jason.encode!(report))
if result != :ok, do: System.halt(1)
