# Disposable Shaping probe: does the running controller pick up a Candidate
# recompile of a late-called module, with and without preloading?
preload = System.get_env("PRELOAD") == "1"
if preload do
  Application.load(:kogen)
  for m <- Application.spec(:kogen, :modules), do: Code.ensure_loaded!(m)
end
mod = Kogen.Build.Report
loaded_at_start = :code.is_loaded(mod) != false
src = "lib/kogen/build/report.ex"
orig = File.read!(src)
try do
  File.write!(src, String.replace(orig, ~r/\nend\s*\z/, "\n  def probe_marker, do: :candidate\nend\n"))
  {out, 0} = System.cmd("mix", ["compile"], stderr_to_stdout: true)
  Code.ensure_loaded(mod)
  IO.puts(Jason.encode!(%{preload: preload, report_loaded_before_recompile: loaded_at_start,
    compile: String.trim(out), running_vm_sees_candidate_function: function_exported?(mod, :probe_marker, 0)}))
after
  File.write!(src, orig)
  System.cmd("mix", ["compile"], stderr_to_stdout: true)
end
