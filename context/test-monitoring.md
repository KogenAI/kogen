# Test Monitoring Patterns

When running long-duration test suites (e.g., `make test-stacks`, `make test-all`), use these patterns to monitor progress without blocking your terminal or losing output.

## Pattern 1: Poll Process with Status Messages (Simplest)

```bash
until ! pgrep -f "make test-stacks" > /dev/null 2>&1; do
  echo "test-stacks still running..."
  sleep 10
done && echo "✅ test-stacks completed"
```

**How it works**:

- `pgrep -f "make test-stacks"` finds the process by command name
- `! ... > /dev/null 2>&1` inverts the result (true when process NOT found)
- `until` loop sleeps 10 seconds, checks again
- When process exits, loop breaks and prints completion message

**Pros**:

- Zero dependencies (pgrep is standard on macOS/Linux)
- Works in any shell (bash, zsh, sh)
- Simple loop, easy to understand
- Outputs status every N seconds

**Cons**:

- Doesn't capture test output (it streams to stdout)
- Polling has delay (up to 10 seconds before detecting completion)

**Use case**: Quick check while working on other tasks; you'll be notified when done.

---

## Pattern 2: Background Command with Output File (Robust)

```bash
make test-stacks 2>&1 | tail -50 > /tmp/test-stacks.log &
# Check progress anytime:
tail -50 /tmp/test-stacks.log
# Or watch live:
tail -f /tmp/test-stacks.log
```

**How it works**:

- `make test-stacks 2>&1` runs the test, capturing stdout + stderr
- `| tail -50` keeps only the last 50 lines (prevents log bloat)
- `> /tmp/test-stacks.log &` redirects to file and runs in background (& fork)
- `tail -50` shows current log; `tail -f` streams new lines

**Pros**:

- Non-blocking (& forks to background)
- Full test output captured in log file
- Can review output anytime without re-running
- `tail -f` gives live streaming if you want to watch

**Cons**:

- Creates temp file (manual cleanup needed)
- `tail -50` truncates; full test output only in log

**Use case**: Development cycles where you want to run tests, context-switch to other work, then review results later.

---

## Pattern 3: Claude Code Background Task (Integrated)

```bash
# In Claude Code terminal (any tool or Bash invocation):
make test-stacks 2>&1 | tail -50  # runs in background automatically
```

**How it works**:

- Claude Code's Bash tool detects long-running commands
- Shows: `Status: running | Runtime: 12m 51s | Output: No output available`
- UI displays completion when the process exits
- No manual polling needed

**Pros**:

- Fully integrated into Claude Code UI
- Zero manual work (no pgrep, no background jobs)
- Automatic notification when done
- Output available if you check the status panel

**Cons**:

- Requires Claude Code (not standalone shell)
- Output only available in Claude Code status panel

**Use case**: Interactive Claude Code sessions where the extension manages the background task lifecycle.

---

## Choosing a Pattern

| Scenario                           | Pattern     | Why                                |
| ---------------------------------- | ----------- | ---------------------------------- |
| Quick CLI check; don't need output | 1 (poll)    | Simplest, instant feedback         |
| Dev cycle; test + context-switch   | 2 (file)    | Output captured; non-blocking      |
| Claude Code session                | 3 (bg task) | Native integration; no manual work |
| Multiple tests; compare results    | 2 (file)    | Easy to log multiple runs          |
| Live streaming during test         | 2 + tail -f | Real-time output to terminal       |

---

## Troubleshooting

### Test output too long?

Use `tail -N` to limit output:

```bash
# Keep last 100 lines
make test-stacks 2>&1 | tail -100 > /tmp/test-stacks.log &
```

### Test doesn't appear to be running?

Check if it's still active:

```bash
pgrep -f "make test-stacks" && echo "running" || echo "not found"
```

### Want to kill a long-running test?

```bash
pkill -f "make test-stacks"  # Kills the process
# Or in Claude Code: use Esc/Ctrl+C to interrupt
```

### Save multiple test runs for comparison?

```bash
make test-stacks 2>&1 | tail -100 > /tmp/test-stacks-$(date +%s).log &
# Creates: /tmp/test-stacks-1654234567.log, etc.
```

---

## Related

- `context/development.md` — Make targets, tech stack
- `context/test-harness.md` — Test suite structure, interpreting results
- `CLAUDE.md` — Full dev cycle and orchestrator rules

## Trigger Keywords

test monitoring, make test-stacks progress, background test, pgrep poll, tail -f log, non-blocking test run, watch test output
