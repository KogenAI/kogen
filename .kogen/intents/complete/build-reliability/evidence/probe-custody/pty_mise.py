import pty, os, sys, time, select, signal
pid, fd = pty.fork()
if pid == 0:
    os.execvp("mise", ["mise","exec","--","mix","run","--no-start","-e",'IO.puts("READY"); Process.sleep(:infinity)'])
out=b""; t0=time.time(); sent=None; status=None
while time.time()-t0<25:
    r,_,_=select.select([fd],[],[],0.2)
    if r:
        try: d=os.read(fd,4096)
        except OSError: break
        if not d: break
        out+=d
    if sent is None and b"READY" in out: sent=time.time(); os.write(fd,b"\x03")
    done,st=os.waitpid(pid, os.WNOHANG)
    if done: status=st; break
else:
    os.kill(pid, signal.SIGKILL); os.waitpid(pid,0)
print("exited_after", sent and round(time.time()-sent,2), "status", status, repr(out.decode(errors="replace")[-120:]))
