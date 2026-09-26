# Probe: terminal detection and notifier (2026-09-26, clone of main 7ed41f66)

**Terminal detection** (`tty.exs`)
- Piped: `mix run --no-start tty.exs | cat` gives `:io.columns()`
  `{:error, :enotsup}`, `IO.ANSI.enabled?` false and
  `:io.getopts(:standard_io)[:terminal]` false. Only the finished line is
  printed.
- Under a real pty (Python `pty.fork`, `pty-probe.txt`): `:io.columns()` is
  **still** `{:error, :enotsup}`, while `terminal` and `IO.ANSI.enabled?` are
  both true.
- **Decision:** detect a terminal with
  `Keyword.get(:io.getopts(:standard_io), :terminal)`, never with
  `:io.columns()`.
- In-place updates use `\r\e[2K` and are written only when that option is true.

**Notifier** (`notify-probe.txt`)
- `afplay -v 0.3 /System/Library/Sounds/Glass.aiff` exits 0 and blocks about
  1.5 s.
- `osascript -e 'display notification … with title …'` exits 0.
- `afplay` on a missing file exits 1, which is the fallback-bell path.
- Glass.aiff and Basso.aiff exist in `/System/Library/Sounds`.
- **Limitation:** whether the banner is displayed depends on macOS
  notification permission for the script host. Exit 0 does not prove display.
