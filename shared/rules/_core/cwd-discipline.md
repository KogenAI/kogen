# Working Directory Discipline

You start in a specific cwd. The launcher (`codegen-build` / `claude-build` / plain `claude`) `cd`s into the project root before exec'ing you. All file outputs MUST land relative to that cwd. When running in a worktree, the cwd is a git worktree directory under `.claude/worktrees/<name>/` rather than the main checkout.

## Hard Rules

- **NEVER** write project source files to absolute `/tmp/` paths (e.g. `/tmp/index.html`, `/tmp/todo_app/lib/...`).
- **NEVER** invoke generators with absolute scratch paths: `mix phx.new /tmp/myapp` is FORBIDDEN — use `mix phx.new myapp` or `mix phx.new .` so the app lands at `./myapp/` or in cwd.
- **NEVER** Bash `cat > /tmp/<file>` for final outputs.
- **ALWAYS** use the Write tool with a relative path (`static/index.html`, `lib/my_app/foo.ex`) or an absolute path THAT STARTS WITH the cwd you were given.

## Permitted /tmp/ Usage

`/tmp/` is allowed ONLY as a scratch directory for intermediate processing that then copies the result back into the project tree. Examples:

- Image pipeline: `cp src.png /tmp/work.png && sips /tmp/work.png ... && cp /tmp/work.png static/images/final.png`. The final destination is `static/images/`, not `/tmp/`.
- Hook-payload probes during debug: `cat > /tmp/hook-probe-*.json` for one-shot diagnostic dumps the user reads.

The test/build harnesses provision an isolated cwd per run. Writing project files outside that cwd causes test assertions like `Path.wildcard(Path.join(cwd, "**/*.html"))` to find nothing and fail the build.

## Counter-Example (FORBIDDEN)

```bash
cat > /tmp/index.html <<'EOF'
<!doctype html>...
EOF
```

## Correct

```
Write tool, file_path: static/index.html
```

Or from Bash if a generator is the only option, scope to cwd:

```bash
mix phx.new . --no-mailer  # current dir
# NOT
mix phx.new /tmp/some_app
```

## Session Log Naming

The session-log naming rule in this prompt governs naming/schema; this path-form rule governs relative-vs-absolute. Both rules must be satisfied:

- Path form: relative OR absolute starting with cwd (see the Hard Rules above)
- Schema: matches canonical regex in the session-log naming rule in this prompt
