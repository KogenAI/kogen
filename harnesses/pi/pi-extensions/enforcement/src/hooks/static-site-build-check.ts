/**
 * static-site-build-check.ts — Pi enforcement: run static site build check
 * on developer session shutdown (SubagentStop equivalent).
 *
 * Mirrors: templates/shared/hooks/static-site-build-check.sh
 * Event: session_shutdown (SubagentStop equivalent)
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { parseAgentType, debugLog } from "../lib/hook-helpers";
import {
  execSync,
  type ExecSyncOptionsWithStringEncoding,
} from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";

export const HANDLER_META = {
  name: "static-site-build-check",
  event: "session_shutdown",
  matcher: "developer-html|developer-hugo|developer-vite",
} as const;

const STATIC_DEV_AGENTS = new Set([
  "developer-html",
  "developer-hugo",
  "developer-vite",
]);

export function register(pi: ExtensionAPI): void {
  pi.on("session_shutdown", async (event) => {
    const ev = event as {
      input?: { cwd?: string; stop_hook_active?: boolean };
    };
    if (ev?.input?.stop_hook_active) return;

    const agentType = parseAgentType();
    if (!STATIC_DEV_AGENTS.has(agentType)) return;

    const projectDir = ev?.input?.cwd ?? process.env["CWD"] ?? process.cwd();
    debugLog("static-site-build-check", `agent=${agentType} cwd=${projectDir}`);

    // No package.json → Hugo case; runner not applicable, skip ALL CLEAR (not a build project)
    if (!fs.existsSync(path.join(projectDir, "package.json"))) {
      debugLog(
        "static-site-build-check",
        "no package.json — Hugo/static site, skipping npm build check",
      );
      return;
    }

    try {
      execSync("make ci", {
        cwd: projectDir,
        stdio: "pipe",
      });
      debugLog("static-site-build-check", "build OK");
    } catch (err) {
      const output =
        (err as { stdout?: Buffer; stderr?: Buffer }).stdout?.toString() ?? "";
      const errOutput =
        (err as { stdout?: Buffer; stderr?: Buffer }).stderr?.toString() ?? "";
      debugLog("static-site-build-check", `build FAILED: ${errOutput}`);
      // Log to stderr for orchestrator visibility (Pi doesn't support decision:block in session_shutdown)
      process.stderr.write(
        `[pi-enforcement:static-site-build-check] build FAILED:\n${output}\n${errOutput}\n`,
      );
      return;
    }

    // ── Render verification ────────────────────────────────────────────────
    // Determine output dir (public/ or dist/).
    const outputDir = fs.existsSync(path.join(projectDir, "dist"))
      ? path.join(projectDir, "dist")
      : path.join(projectDir, "public");

    if (!fs.existsSync(outputDir)) {
      debugLog(
        "static-site-build-check",
        "no output dir — skipping render check",
      );
      return;
    }

    const codegenDir = process.env["CODEGEN_DIR"] ?? "";
    const renderCheckScript = codegenDir
      ? path.join(
          codegenDir,
          "harnesses",
          "claude",
          "hooks",
          "lib",
          "render-check.js",
        )
      : "";

    if (!renderCheckScript || !fs.existsSync(renderCheckScript)) {
      debugLog(
        "static-site-build-check",
        "render-check.js not found — skipping",
      );
      return;
    }

    let renderRaw = "";
    try {
      const opts: ExecSyncOptionsWithStringEncoding = {
        cwd: codegenDir || projectDir,
        stdio: ["ignore", "pipe", "pipe"],
        timeout: 35_000,
        encoding: "utf8",
      };
      renderRaw = execSync(
        `node "${renderCheckScript}" --mode static --timeout 30000 "${outputDir}"`,
        opts,
      ).toString();
    } catch (err) {
      renderRaw =
        (err as { stdout?: Buffer | string }).stdout?.toString() ?? "";
    }

    const verdictLine = renderRaw
      .split("\n")
      .find((l) => l.startsWith("RENDER_VERDICT="));
    const renderVerdict = verdictLine ? verdictLine.split("=")[1] : "";

    debugLog("static-site-build-check", `render verdict: ${renderVerdict}`);

    // Pi doesn't support decision:block in session_shutdown; this gate is advisory only (stderr).
    // The claude harness has the fail-closed enforcement.
    if (renderVerdict.startsWith("FAIL:")) {
      const reason = renderVerdict.slice("FAIL:".length);
      process.stderr.write(
        `[pi-enforcement:static-site-build-check] render FAILED: ${reason}\n`,
      );
    } else if (renderVerdict === "INCONCLUSIVE:browser-not-installed") {
      // Explicit browser-absent verdict from render-check.js
      debugLog(
        "static-site-build-check",
        "render INCONCLUSIVE: browser not installed",
      );
      process.stderr.write(
        `[pi-enforcement:static-site-build-check] render INCONCLUSIVE: Chromium browser not found — run: npx playwright install chromium\n`,
      );
    } else if (renderVerdict === "") {
      // render-check.js crashed or emitted no RENDER_VERDICT= line
      debugLog(
        "static-site-build-check",
        "render-check emitted no verdict — crash or parse error",
      );
      process.stderr.write(
        `[pi-enforcement:static-site-build-check] render-check did not emit verdict — check render-check.js for parse/runtime errors\n`,
      );
    } else if (renderVerdict.startsWith("INCONCLUSIVE:")) {
      const detail = renderVerdict.slice("INCONCLUSIVE:".length);
      debugLog(
        "static-site-build-check",
        `render INCONCLUSIVE: ${detail} — downgrade to INCONCLUSIVE (not ALL CLEAR)`,
      );
      // Render INCONCLUSIVE → surface as INCONCLUSIVE warning, not silent pass
      process.stderr.write(
        `[pi-enforcement:static-site-build-check] render INCONCLUSIVE: ${detail} — gate is inconclusive, not ALL CLEAR\n`,
      );
    }
    // Write cycle-state.json to record GATED verdict for this build.
    // Absent when build already failed (early return above).
    try {
      const gateResultDir = path.join(projectDir, "codegen", "gate-pending");
      fs.mkdirSync(gateResultDir, { recursive: true });
      const cycleVerdict = renderVerdict.startsWith("INCONCLUSIVE:")
        ? "inconclusive"
        : renderVerdict.startsWith("FAIL:")
          ? "failed"
          : "clear";
      const cycleState = {
        state: "GATED",
        step_log: "",
        session_id:
          process.env["SESSION_ID"] ?? process.env["CLAUDE_SESSION_ID"] ?? "",
        verdict: cycleVerdict,
        updated_at: new Date().toISOString(),
      };
      fs.writeFileSync(
        path.join(gateResultDir, "cycle-state.json"),
        JSON.stringify(cycleState, null, 2),
      );
      debugLog(
        "static-site-build-check",
        `wrote cycle-state.json state=GATED verdict=${cycleVerdict}`,
      );
    } catch (e) {
      debugLog(
        "static-site-build-check",
        `failed to write cycle-state.json: ${String(e)}`,
      );
    }
    // PASS: no action needed (non-blocking success)
  });
}
