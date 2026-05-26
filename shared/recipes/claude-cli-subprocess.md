# Recipe: Claude CLI as Build Engine (Elixir Subprocess)

## Problem

You want to invoke `claude --print` from Elixir (e.g., from an Oban worker) to autonomously edit code in a target directory, but face several issues:

- Claude Code environment variables (`CLAUDECODE`, `CLAUDE_CODE_SSE_PORT`, `CLAUDE_CODE_ENTRYPOINT`) conflict when spawning from within Claude Code
- `--output-format stream-json` produces JSON lines that need parsing to be human-readable
- Subagents spawned by Claude can escape the target directory sandbox
- Standard `System.cmd` doesn't support shell pipes needed for log streaming
- Without `--dangerously-skip-permissions`, Claude silently exits 1 with empty output when stdin is `/dev/null`
- Claude binary may not be at `/usr/local/bin/claude` — use `which claude` or `System.find_executable("claude")`

## Solution

Invoke `claude --print --output-format stream-json` via `System.cmd("sh", ["-c", cmd])` with:

1. Unset conflicting env vars via `env -u` prefix
2. Lock down tool access via `--disallowed-tools`
3. Confine to target directory via `--system-prompt`
4. Stream JSON through a Python log parser written to `/tmp` at runtime

For lightweight classification (Haiku), write output to a `/tmp` file instead of reading stdout — avoids TTY buffering issues.

## Implementation

### Full Build Worker (Sonnet via shell pipe)

```elixir
defmodule MyApp.Builds.BuildWorker do
  use Oban.Worker, queue: :builds, max_attempts: 3

  @claude_path Application.compile_env(:my_app, :claude_path, "/usr/local/bin/claude")

  defp run_claude(prompt, app_path, log_path) do
    File.mkdir_p!(Path.dirname(log_path))

    system_prompt =
      "You are a code editor working ONLY on the Phoenix app at #{app_path}. " <>
      "CRITICAL: You MUST only read and modify files inside #{app_path}. " <>
      "Do NOT access any files outside of #{app_path}. " <>
      "Read the relevant files, make ALL necessary changes to fulfil the request, then stop. " <>
      "Do not explain, do not ask questions — just edit the files."

    readable_log_path = String.replace_suffix(log_path, ".log", ".readable.log")
    parser_path = write_log_parser(log_path, readable_log_path)

    # env -u unsets Claude Code's own env vars that conflict with subprocess
    # --disallowed-tools prevents subagents from escaping the sandbox
    # sh -c enables shell piping
    cmd =
      "env -u CLAUDECODE -u CLAUDE_CODE_SSE_PORT -u CLAUDE_CODE_ENTRYPOINT " <>
      "#{@claude_path} --print --verbose --output-format stream-json --model sonnet " <>
      "--dangerously-skip-permissions " <>
      "--system-prompt #{shell_escape(system_prompt)} " <>
      "#{shell_escape(prompt)} " <>
      "--disallowed-tools Agent,Skill,EnterPlanMode,ExitPlanMode,EnterWorktree " <>
      "< /dev/null 2>&1 | python3 -u #{shell_escape(parser_path)}"

    case System.cmd("sh", ["-c", cmd], cd: app_path) do
      {_, 0} -> :ok
      {_, code} -> {:error, "claude exited with code #{code}"}
    end
  rescue
    e -> {:error, "subprocess error: #{Exception.message(e)}"}
  end

  # Write a Python parser that splits stream-json into raw JSON + human-readable log
  defp write_log_parser(raw_log_path, readable_log_path) do
    parser_path = raw_log_path <> ".parser.py"

    script = """
    import sys, json, datetime

    raw = open(#{inspect(raw_log_path)}, 'w')
    readable = open(#{inspect(readable_log_path)}, 'w', buffering=1)

    for line in sys.stdin:
        raw.write(line)
        raw.flush()
        try:
            d = json.loads(line)
            t = d.get('type')
            if t == 'assistant':
                for block in d.get('message', {}).get('content', []):
                    if block.get('type') == 'tool_use':
                        name = block.get('name', '?')
                        inp = block.get('input', {})
                        detail = (
                            inp.get('file_path') or
                            inp.get('command') or
                            inp.get('pattern') or
                            inp.get('description') or ''
                        )
                        ts = datetime.datetime.now().strftime('%H:%M:%S')
                        readable.write(f'[{ts}] {name}: {str(detail)[:120]}\\n')
            elif t == 'result':
                ts = datetime.datetime.now().strftime('%H:%M:%S')
                cost = d.get('cost_usd', '?')
                readable.write(f'[{ts}] DONE (cost=${cost})\\n')
        except Exception:
            pass

    raw.close()
    readable.close()
    """

    File.write!(parser_path, script)
    parser_path
  end

  defp shell_escape(str) do
    "'" <> String.replace(str, "'", "'\\''") <> "'"
  end
end
```

### Classification Worker (Haiku via file output)

For lightweight classification, write to `/tmp` instead of piping — avoids TTY buffering:

```elixir
defmodule MyApp.AI do
  @claude_path Application.compile_env(:my_app, :claude_path, "/usr/local/bin/claude")

  def classify(prompt) do
    out_file = "/tmp/my_app_claude_#{:rand.uniform(999_999)}.json"

    cmd =
      "env -u CLAUDECODE -u CLAUDE_CODE_SSE_PORT -u CLAUDE_CODE_ENTRYPOINT " <>
      "#{@claude_path} --print --verbose --output-format stream-json --model haiku " <>
      "--dangerously-skip-permissions " <>
      "#{shell_escape(prompt)} " <>
      "--disallowed-tools Agent,Skill,EnterPlanMode,ExitPlanMode,EnterWorktree " <>
      "< /dev/null > #{out_file} 2>&1"

    result =
      case System.cmd("sh", ["-c", cmd]) do
        {_, 0} -> parse_stream_json_result(out_file)
        {_, code} ->
          output = File.read(out_file) |> elem(1)
          {:error, "claude exited #{code}: #{output}"}
      end

    File.rm(out_file)
    result
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp parse_stream_json_result(file) do
    case File.read(file) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.find_value(fn line ->
          case Jason.decode(line) do
            {:ok, %{"type" => "result", "result" => text}} -> {:ok, String.trim(text)}
            _ -> nil
          end
        end)
        |> case do
          nil -> {:error, "no result in output"}
          result -> result
        end

      {:error, reason} ->
        {:error, "could not read output file: #{reason}"}
    end
  end
end
```

## Considerations

- **`env -u` is mandatory when running from Claude Code**: The `CLAUDECODE` env var tells the Claude binary it's running inside Claude Code, which changes its behavior. Always unset `CLAUDECODE`, `CLAUDE_CODE_SSE_PORT`, `CLAUDE_CODE_ENTRYPOINT`.
- **`--disallowed-tools` must come AFTER the prompt arg**: `--disallowed-tools` is variadic (`<tools...>`) and consumes subsequent args as tool names. Place it after `shell_escape(prompt)` or Claude will swallow the prompt and exit 1 with "Input must be provided". Always: `"#{shell_escape(prompt)} --disallowed-tools ... < /dev/null"`
- **`--disallowed-tools Agent,...`**: Without this, Claude can spawn subagents that escape the `cd: app_path` sandbox into the parent repo. Always disable Agent, Skill, EnterPlanMode, ExitPlanMode, EnterWorktree.
- **`< /dev/null`**: Claude expects a terminal when invoked interactively. Redirect stdin from `/dev/null` for non-interactive subprocess use.
- **`--dangerously-skip-permissions` is mandatory**: Without it, Claude pauses for permission prompts and exits 1 when stdin is `/dev/null`. The failure produces an empty error message — hard to diagnose. Always include this flag for any non-interactive subprocess call.
- **Verify the binary path at runtime**: Claude is often installed to `~/.local/bin/claude`, not `/usr/local/bin/claude`. Use `System.find_executable("claude")` in config. Test manually with `which claude` before assuming a path works.
- **Python parser `-u` flag**: Use `python3 -u` for unbuffered output so logs appear in real time.
- **`shell_escape/1`**: Single-quote shell escaping. Required for prompts containing special characters.
- **System.cmd env inheritance**: `System.cmd` with an `env:` option replaces the entire OS environment. Always inherit `PATH HOME MIX_HOME HEX_HOME ELIXIR_ERL_OPTIONS ERL_LIBS` when running mix commands from the subprocess.

## Example Usage

```elixir
# In an Oban worker
defp run_claude(prompt, app_path, log_path) do
  # ... (see above)
end

# Tail readable log while build runs
# tail -f /apps/my-app/builds/job-id.readable.log
```

## Related Recipes

- `elixir-python-system-cmd.md` — General System.cmd patterns
