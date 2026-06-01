# Node.js Process Management — Process Groups & Signals

Detached child processes + signal handling patterns for clean shutdown.

## Spawning Detached Processes

`spawn({ detached: true })` creates a new process group (PGID). Essential when spawning long-running services (e.g., `mix phx.server`) from Node to prevent child from becoming zombie when parent exits.

```javascript
const child = spawn(cmd, args, { detached: true });
```

Result: child runs in its own process group; parent can exit independently without orphaning the child.

## Process Group Termination

Kill the entire process group (parent + all children, including BEAM VM and Erlang processes):

```javascript
process.kill(-pid, signal); // negative pid = process group
```

**Signal sequence**:

1. SIGTERM (-15) — graceful shutdown (15s timeout for app to cleanup)
2. SIGKILL (-9) — forced termination if SIGTERM doesn't land

Catch ESRCH (process already exited) in try/catch — normal exit case.

## Example: Long-Running Server Cleanup

```javascript
const child = spawn("mix", ["phx.server"], {
  env: { PORT: dynamicPort },
  detached: true,
});

// Wait for readiness, capture assets, etc...

// Cleanup: term → wait → kill
try {
  process.kill(-child.pid, "SIGTERM");
  await new Promise((r) => setTimeout(r, 2000)); // 2s grace period
  process.kill(-child.pid, "SIGKILL");
} catch (e) {
  if (e.code !== "ESRCH") throw e; // ESRCH = already exited, OK
}
```
