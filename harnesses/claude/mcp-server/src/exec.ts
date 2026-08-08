// exec.ts — sole point where this server shells out to the codegen-log binary.
// NEVER string-interpolate args into a shell command: execFileSync takes an
// array argv (no shell), and any body text rides on stdin via {input}. This
// keeps arbitrary body content (e.g. a "make test" phrase, or shell
// metacharacters) out of any Bash-scanner surface and out of shell quoting
// entirely — the load-bearing correctness property this server exists for.

import { execFileSync } from "node:child_process";

export interface ExecResult {
  ok: boolean;
  stdout: string;
  stderr: string;
}

/**
 * Run codegen-log with the given argv, optionally piping `stdinBody` to it.
 * Resolves the binary via PATH (same PATH the parent claude process
 * inherits) — never hardcodes an absolute repo path, since repo root
 * differs per machine (see context/deployment-topology.md).
 */
export function runCodegenLog(args: string[], stdinBody?: string): ExecResult {
  try {
    const stdout = execFileSync("codegen-log", args, {
      input: stdinBody ?? "",
      encoding: "utf8",
      stdio: ["pipe", "pipe", "pipe"],
    });
    return { ok: true, stdout, stderr: "" };
  } catch (err: unknown) {
    const e = err as {
      stdout?: Buffer | string;
      stderr?: Buffer | string;
      message?: string;
    };
    const stdout = e.stdout ? e.stdout.toString() : "";
    const stderr = e.stderr ? e.stderr.toString() : (e.message ?? String(err));
    return { ok: false, stdout, stderr };
  }
}

/**
 * Run codegen-advise for the CURRENT build harness, piping the context text
 * on stdin (codegen-advise reads stdin when --context is omitted). The
 * stronger-model tier of the SAME harness is chosen internally by
 * codegen-advise itself — this server never picks it. `cwd` is REQUIRED and
 * passed explicitly as `--cwd=<path>`: codegen-advise assembles a packet
 * (git HEAD/diff/base-attribution/gate artifacts) from that path, and an
 * inherited process cwd would silently collect the wrong repo's state when
 * this server's own working directory differs from the active build (see
 * pitch "the advisor is handed a paragraph" D-9). Sibling of runCodegenLog;
 * a distinct helper (not a reuse) since it wraps a different binary with a
 * different argv shape.
 */
export function runCodegenAdvise(
  current: "claude_code",
  cwd: string,
  context: string,
): ExecResult {
  try {
    const stdout = execFileSync(
      "codegen-advise",
      [`--harness=${current}`, `--cwd=${cwd}`],
      {
        input: context,
        encoding: "utf8",
        stdio: ["pipe", "pipe", "pipe"],
        cwd,
      },
    );
    return { ok: true, stdout, stderr: "" };
  } catch (err: unknown) {
    const e = err as {
      stdout?: Buffer | string;
      stderr?: Buffer | string;
      message?: string;
    };
    const stdout = e.stdout ? e.stdout.toString() : "";
    const stderr = e.stderr ? e.stderr.toString() : (e.message ?? String(err));
    return { ok: false, stdout, stderr };
  }
}
