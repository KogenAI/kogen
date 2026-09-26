import pty, os, sys, time, select, signal
def run(label, env_extra, action):
    env = dict(os.environ, **env_extra)
    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe("mix", ["mix","run","--no-start","-e",'IO.puts("READY"); Process.flag(:trap_exit, true); :os.set_signal(:sighup, :handle); Process.sleep(:infinity)'], env)
    out=b""; t0=time.time(); sent=None
    while time.time()-t0<25:
        r,_,_=select.select([fd],[],[],0.2)
        if r:
            try: d=os.read(fd,4096)
            except OSError: break
            if not d: break
            out+=d
        if sent is None and b"READY" in out:
            sent=time.time()
            if action=="ctrl-c": os.write(fd,b"\x03")
            elif action=="sighup": os.kill(pid, signal.SIGHUP)
        done,status=os.waitpid(pid, os.WNOHANG)
        if done: break
    else:
        os.kill(pid, signal.SIGKILL); os.waitpid(pid,0); status=None
    exited = sent and (time.time()-sent)
    tail=out.decode(errors="replace")[-160:].replace("\r"," ").replace("\n"," | ")
    print(f"{label:28} exited_after={exited and round(exited,2)} status={status} tail={tail!r}")
run("ctrl-c default", {}, "ctrl-c")
run("ctrl-c +Bd", {"ELIXIR_ERL_OPTIONS":"+Bd"}, "ctrl-c")
run("ctrl-c +Bc", {"ELIXIR_ERL_OPTIONS":"+Bc"}, "ctrl-c")
run("sighup default", {}, "sighup")
