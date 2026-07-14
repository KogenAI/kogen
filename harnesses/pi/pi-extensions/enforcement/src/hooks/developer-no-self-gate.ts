/**
 * developer-no-self-gate.ts — Pi enforcement: count CI/test invocations and
 * block after threshold.
 *
 * Mirrors: templates/shared/hooks/developer-no-self-gate.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  deny,
  parseAgentType,
  debugLog,
  isCodegenLogWrite,
} from "../lib/hook-helpers";
import { execSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

export const HANDLER_META = {
  name: "developer-no-self-gate",
  event: "tool_call",
  matcher: "bash",
} as const;

const DEV_AGENTS = new Set([
  "developer-phoenix-backend",
  "developer-phoenix-frontend",
  "developer-static",
]);

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;

    const agentType = parseAgentType();
    if (!DEV_AGENTS.has(agentType)) return;

    const command: string = (event.input as { command?: string }).command ?? "";
    debugLog("developer-no-self-gate", `agent=${agentType} cmd=${command}`);

    // A codegen-log write narrates gated phrases in its heredoc body; it is
    // never the gated action itself. Bypass before any phrase match or
    // counter increment.
    if (isCodegenLogWrite(command)) return;

    if (
      !/\bmix\s+(test|credo|format)\b|\bmake\s+(ci|ci-fast|test)\b/.test(
        command,
      )
    ) {
      return;
    }

    const sessionId =
      (event as { sessionId?: string }).sessionId ??
      process.env["SESSION_ID"] ??
      "unknown";

    // ── Loop-mode: progress-bounded self-verify ───────────────────────────
    // Under the Elixir loop (CODEGEN_LOOP=1) the developer runs the
    // delegated gate itself, in its own warm session, and must keep fixing
    // red until it is green. A raw count-of-3 cap would wedge that workflow
    // on a real multi-red fix cycle. Instead, bound retries by PROGRESS:
    // allow a gate re-run whenever the working tree's content signature
    // changed since the last gate run (the dev made an edit); deny on a
    // pure spin (signature unchanged — nothing was fixed). A hard ceiling
    // (15) still backstops runaway loops regardless of continued progress.
    if (process.env["CODEGEN_LOOP"] === "1") {
      const cwd = process.env["CWD"] ?? process.cwd();
      const signature = computeTreeSignature(cwd);

      const sigFile = path.join(
        os.tmpdir(),
        `codegen-self-gate-${sessionId}.sig`,
      );

      // CODEGEN_RESUME_ATTEMPT is set by the loop on a warm-resume transient
      // retry (same session id as the attempt that dropped). Without this, a
      // developer that drops mid-gate resumes into an UNCHANGED tree (it
      // never got to make the fixing edit) and would be denied here as a
      // "pure spin" even though nothing was actually re-run yet. A NEW
      // resume token vs. the last-seen one is treated as a fresh first-run:
      // allow, and reset the stored signature — the hard ceiling below still
      // applies regardless, so this only removes the false-positive.
      const resumeToken = process.env["CODEGEN_RESUME_ATTEMPT"] ?? "";

      let prevSig = "";
      let prevCount = 0;
      let prevResumeToken = "";
      try {
        const raw = fs.readFileSync(sigFile, "utf8");
        const lines = raw.split("\n");
        prevSig = lines[0] ?? "";
        prevCount = parseInt(lines[1] ?? "0", 10) || 0;
        prevResumeToken = lines[2] ?? "";
      } catch {
        prevSig = "";
        prevCount = 0;
        prevResumeToken = "";
      }

      const newCount = prevCount + 1;

      debugLog(
        "developer-no-self-gate",
        `loop-mode session=${sessionId} count=${newCount} sig=${signature} prevSig=${prevSig} resumeToken=${resumeToken} prevResumeToken=${prevResumeToken}`,
      );

      if (newCount >= 15) {
        fs.writeFileSync(sigFile, `${signature}\n${newCount}\n${resumeToken}\n`);
        return deny(
          "BLOCKED by developer-no-self-gate: hard ceiling (15 gate self-verify runs) reached this session — hand back to the loop rather than continuing to retry.",
        );
      }

      if (resumeToken !== "" && resumeToken !== prevResumeToken) {
        // First gate check under a NEW resume token → treat as a fresh run,
        // not a spin, regardless of the tree signature.
        fs.writeFileSync(sigFile, `${signature}\n${newCount}\n${resumeToken}\n`);
        return;
      }

      if (prevSig === "" || signature !== prevSig) {
        // First run, or the tree changed since the last gate run → progress.
        fs.writeFileSync(sigFile, `${signature}\n${newCount}\n${resumeToken}\n`);
        return;
      }

      // Signature unchanged → pure spin, nothing was fixed since last run.
      fs.writeFileSync(sigFile, `${signature}\n${newCount}\n${resumeToken}\n`);
      return deny(
        "BLOCKED by developer-no-self-gate: the gate command was re-run with NO change to the working tree since the last run — that cannot fix anything. Make an edit that addresses the failure, or hand back to the loop if you are stuck.",
      );
    }

    // ── Legacy (non-loop) mode: raw count-of-3 cap ─────────────────────────
    const counterFile = path.join(
      os.tmpdir(),
      `codegen-self-gate-${sessionId}.count`,
    );

    let count = 0;
    try {
      const raw = fs.readFileSync(counterFile, "utf8").trim();
      count = parseInt(raw, 10) || 0;
    } catch {
      count = 0;
    }

    count += 1;
    fs.writeFileSync(counterFile, String(count));
    debugLog("developer-no-self-gate", `session=${sessionId} count=${count}`);

    if (count >= 3) {
      return deny(
        `BLOCKED by developer-no-self-gate: return control to orchestrator. You have run CI/test commands ${count} times in this session. Complete your implementation and stop — the loop's LoopGate runs the full gate after your turn.`,
      );
    }
  });
}

// Content-hash of the tracked+untracked working tree (excluding gitignored
// paths) at `cwd` — mirrors the bash hook and Elixir tree_signature/1
// exactly (`git ls-files -oc --exclude-standard | sort | xargs shasum |
// shasum | cut -d' ' -f1`). Returns "" when `cwd` is not a git work tree
// (or git/shasum is unavailable) — a legitimate "no signature available"
// case the caller falls back to on.
function computeTreeSignature(cwd: string): string {
  try {
    const output = execSync(
      "git ls-files -oc --exclude-standard | sort | xargs shasum | shasum | cut -d' ' -f1",
      { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], shell: "/bin/bash" },
    );
    return output.trim();
  } catch {
    return "";
  }
}
