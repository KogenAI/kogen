alias Kogen.Build.GuardedPaths
fx = System.get_env("FX"); File.rm_rf!(fx); File.mkdir_p!(fx)
sh = fn args -> {o, 0} = System.cmd("git", args, cd: fx, stderr_to_stdout: true); o end
File.write!(Path.join(fx, ".gitignore"), "*.log\n"); File.write!(Path.join(fx, "a.txt"), "a\n")
sh.(["init", "-q"]); sh.(["add", "-A"]); sh.(["-c","user.email=p@p","-c","user.name=p","commit","-qm","base"])
{:ok, snap} = GuardedPaths.capture(fx)
# Candidate: edit .gitignore to hide a new file, and write that file.
File.write!(Path.join(fx, ".gitignore"), "*.log\nhidden.txt\n"); File.write!(Path.join(fx, "hidden.txt"), "sneaky\n")
for guards <- [[], [".gitignore"], [".gitignore", "hidden.txt"]] do
  IO.puts("guards=#{inspect(guards)} -> #{inspect(GuardedPaths.check(snap, guards))}")
end
# Control: .gitignore edit alone, declared.
File.rm!(Path.join(fx, "hidden.txt")); File.write!(Path.join(fx, ".gitignore"), "*.log\n*.pid\n")
IO.puts("gitignore-only, guards=[.gitignore] -> #{inspect(GuardedPaths.check(snap, [".gitignore"]))}")
IO.puts("gitignore-only, guards=[] -> #{inspect(GuardedPaths.check(snap, []))}")
