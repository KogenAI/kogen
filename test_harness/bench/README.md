# bench/

Node helpers for benchmark artifact capture.

## Role-Model-Binding Campaigns

`mix codegen.bench.role_model_sweep` (run from `test_harness/`) is a
SEPARATE campaign from `make bench` above — it holds ONE build role's
harness/model/effort fixed across a generated baseline arm and one or more
operator-supplied candidate arms, on ONE live-build workload file, across
repeated repetitions, and writes objective (pass-rate / cost / duration)
comparison evidence to `codegen/benchmarks/<ts>-role-model-<role>/`. See
`CodegenTestHarness.RoleModelSweep` moduledoc for the full campaign-matrix
contract and `mix help codegen.bench.role_model_sweep` for CLI usage.

```sh
cd test_harness
mix codegen.bench.role_model_sweep --matrix ../campaign.yaml --reason "developer-static candidates" --validate-only
mix codegen.bench.role_model_sweep --matrix ../campaign.yaml --reason "developer-static candidates"
```

`--validate-only` runs every no-spend preflight check and prints the
resolved baseline + planned schedule; it never spawns a child build. Agents
may run this form; the paid form (without `--validate-only`) is
operator-only. The task NEVER edits `templates/generator/config.yaml` or
selects a "winner" — it produces evidence for manual operator review.

## Summary

`summarize.js` reads every `runs/<harness>/<stack>/*.jsonl` file, finds the `harness_summary` line in each, aggregates cost / tokens / duration / turns / pass-rate and screenshot counts, then writes `<BENCH_RUN_DIR>/summary.md`.

Invoked automatically by `make bench` after both harness suites finish. Can also be run manually:

```sh
node test_harness/bench/summarize.js path/to/codegen/benchmarks/<run-dir>
```

The produced `summary.md` contains:

- Run metadata (date, sha, reason, harness versions)
- Pass rate per harness
- Cost table (per-harness, per-stack, grand total)
- Tokens table (input + cache totals, output)
- Duration / turns (missing values render as `—`)
- Full per-test results table
- Screenshot counts per harness / stack

## Screenshots

`screenshot.js` captures a full-page PNG of each static-stack benchmark run.

**Screenshots require Playwright. Install once: `npm install` from this dir.**

After `npm install`, Playwright's Chromium browser is downloaded automatically on first use. If you need to pre-install it explicitly:

```sh
npx playwright install chromium
```

First benchmark run installs Playwright Chromium automatically via npm.

## Stack Detection

`screenshot.js` recognises exactly TWO stacks: `phoenix` (handled in `main()`, spawns its own server) and `static` (mapped to a serve directory by `resolveServeDir()`). Any other `--stack` value hits `resolveServeDir`'s `default:` branch and exits 1 with `Unknown stack: <name>` — there is no `multilingual`, `vite_react` or `vite_vue` branch, whatever earlier revisions of this file claimed.

### Vite Bundle-Marker Detection

An agent may write a source-shape `index.html` into `public/` (e.g. `<!doctype html>...<div id="root"></div>`) without running `npm run build`. With `outDir: "public"` (Vite project rule), the screenshot logic would find `public/index.html` and serve it directly — but it has no `<script src="/assets/index-HASH.js">` reference, so React/Vue never loads and the PNG is blank.

`hasBundledScript(html)` scans the first 4KB of `public/index.html` for a `<script src="...">` pointing to a built asset (hashed filename like `index-UV0H7q2h.js`, or paths under `/assets/` or `/dist/`). If the check fails, the existing file is ignored and the build branch runs, overwriting `public/index.html` with real bundled output. `public/index.html` is the only candidate — `resolveServeDir` never looks at `dist/`.

### Phoenix Server Lifecycle

`case "phoenix"` in `main()` bypasses `resolveServeDir` entirely — Phoenix runs its own HTTP server. Sequence:

1. `allocFreePort()` — bind Node `net.Server` to port 0, capture OS-assigned port, close immediately.
2. `execSync("mix deps.get", { timeout: 60_000 })` — fetch dependencies.
3. `execSync("mix compile", { timeout: 90_000 })` — compile the project; separate timeout gives clear diagnostics if compile is slow.
4. `startPhoenixServer(cwd, port)` — `spawn("mix", ["phx.server"], { detached: true })` in a new process group. Pipes stdout/stderr to `process.stderr` with `[phx]` prefix.
5. `waitForHttp200(port, 30_000)` — poll `http://localhost:<port>/` every 200ms; resolve on 2xx/3xx; treat `ECONNREFUSED` as retry.
6. Chromium screenshot at `http://localhost:<port>/`.
7. `stopPhoenixServer(child)` — `process.kill(-pgid, 'SIGTERM')`, wait 2s, `process.kill(-pgid, 'SIGKILL')`. Both wrapped in try/catch; `ESRCH` treated as success (process already exited). A `process.on('exit', ...)` safety net registered before the try block kills the group even on uncaught exceptions.

### `static`

`resolveServeDir`'s only non-default case. Serve dir is `public/` — the Vite
`outDir` this repo's static scaffold configures (see
`context/scaffold.md` § static SEO baseline).

Detection order:

1. `public/index.html` exists **and** passes the bundle-marker check → serve `public/` (already built)
2. Otherwise → `npm install --silent --no-audit --no-fund` then `npm run build`, then serve `public/`
3. `public/index.html` still absent after the build → throw `Vite build ran but public/index.html not found in <cwd>`

## CSS Injection

SPAs (React, Vue) render onto transparent canvases with low-contrast text, producing visually blank PNGs. Before `page.screenshot()`, `screenshot.js` injects a visibility stylesheet via `page.addStyleTag()` that forces a white background, frames interactive elements with a light border, and sets link colors. This produces a "visibility-normalized" view — useful for confirming a page rendered at all, not for pixel-perfect visual regression. If CSS injection fails (strict CSP), the failure is logged to stderr and the screenshot proceeds with original rendering.
