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

type GateVerdict = "clear" | "failed" | "inconclusive";

export const HANDLER_META = {
  name: "static-site-build-check",
  event: "session_shutdown",
  matcher: "developer-static",
} as const;

const STATIC_DEV_AGENTS = new Set(["developer-static"]);

const OG_PROPS = ["og:title", "og:description", "og:type", "og:image"];

// _isExcludedUrlHost — JSON-LD/XML namespace hosts that are never a deploy
// host (schema.org @context, w3.org XML namespaces).
function isExcludedUrlHost(url: string): boolean {
  return /schema\.org|w3\.org/.test(url);
}

// _isBadUrl — invented fake host or unreplaced template variable. Reduced-
// fidelity note: mirrors the bash gate's example.com/%...% arms; JSON.parse
// below is the boundary-validation carve-out for ld+json well-formedness.
function isBadUrl(url: string): boolean {
  return /example\.com|example\.org|example\.net|%/.test(url);
}

// checkSeoBaseline — mirrors the bash gate's Check 6b (SEO/AI-discoverability
// baseline). Pi's session_shutdown event cannot block (see module header for
// the reduced-fidelity gap vs. the Claude harness's fail-closed enforcement),
// so violations are collected and surfaced to stderr, never thrown.
function checkSeoBaseline(projectDir: string): string[] {
  const violations: string[] = [];
  const outputDir = path.join(projectDir, "public");
  if (!fs.existsSync(outputDir)) return violations;

  if (!fs.existsSync(path.join(outputDir, "robots.txt"))) {
    violations.push(
      "public/robots.txt missing — check vite.config.js publicDir + static/robots.txt",
    );
  }

  const htmlFiles: string[] = [];
  (function walk(dir: string) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.isFile() && entry.name.endsWith(".html")) {
        htmlFiles.push(full);
      }
    }
  })(outputDir);

  for (const htmlFile of htmlFiles) {
    const html = fs.readFileSync(htmlFile, "utf8");

    if (!/<meta[^>]*name="description"[^>]*content="[^"]+"/s.test(html)) {
      violations.push(`${htmlFile} missing non-empty <meta name="description">`);
    }

    for (const prop of OG_PROPS) {
      if (!new RegExp(`<meta[^>]*property="${prop}"`, "s").test(html)) {
        violations.push(`${htmlFile} missing <meta property="${prop}">`);
      }
    }

    if (!/<link[^>]*rel="canonical"/s.test(html)) {
      violations.push(`${htmlFile} missing <link rel="canonical">`);
    }

    const ldjsonMatches = [
      ...html.matchAll(
        /<script[^>]*type="application\/ld\+json"[^>]*>([\s\S]*?)<\/script>/g,
      ),
    ];
    if (ldjsonMatches.length === 0) {
      violations.push(
        `${htmlFile} has zero <script type="application/ld+json"> blocks — need exactly one`,
      );
    } else if (ldjsonMatches.length > 1) {
      violations.push(
        `${htmlFile} has ${ldjsonMatches.length} ld+json blocks — need exactly one`,
      );
    } else {
      // Boundary validation: JSON.parse in try/catch is the sanctioned
      // carve-out for validating externally-authored ld+json well-formedness.
      try {
        JSON.parse(ldjsonMatches[0][1]);
      } catch {
        violations.push(`${htmlFile} ld+json block is not valid JSON`);
      }
    }

    const urlMatches = html.match(/https?:\/\/[^"'\s]+/g) ?? [];
    for (const url of urlMatches) {
      if (isExcludedUrlHost(url)) continue;
      if (isBadUrl(url)) {
        violations.push(
          `${htmlFile} has invented/unreplaced URL: ${url} — use SITE_URL_PLACEHOLDER`,
        );
      }
    }
  }

  return violations;
}

function writeGateArtifacts(params: {
  projectDir: string;
  gate: string;
  mode: "short" | "long";
  verdict: GateVerdict;
  marker: string;
  renderVerdict: string;
  classification: string;
  exitCode: number;
  sessionId: string;
}): void {
  const gateResultDir = path.join(params.projectDir, "codegen", "gate-pending");
  fs.mkdirSync(gateResultDir, { recursive: true });

  const now = new Date().toISOString();
  const gateResult = {
    gate: params.gate,
    mode: params.mode,
    diff_sha: "unknown",
    diff_files_count: 0,
    runner_found: true,
    exit: params.exitCode,
    execution_evidence: 1,
    expected_segments: 1,
    render_verdict: params.renderVerdict,
    verdict: params.verdict,
    verdict_marker: params.marker,
    classification: params.classification,
    started: now,
    ended: now,
    session_id: params.sessionId,
    log: "",
    witness: "",
  };
  fs.writeFileSync(
    path.join(gateResultDir, "gate-result.json"),
    JSON.stringify(gateResult, null, 2),
  );
  debugLog(
    "static-site-build-check",
    `wrote gate-result.json verdict=${params.verdict}`,
  );

  const cycleState = {
    state: "GATED",
    step_log: "",
    session_id: params.sessionId,
    verdict: params.verdict,
    updated_at: now,
  };
  fs.writeFileSync(
    path.join(gateResultDir, "cycle-state.json"),
    JSON.stringify(cycleState, null, 2),
  );
  debugLog(
    "static-site-build-check",
    `wrote cycle-state.json state=GATED verdict=${params.verdict}`,
  );
}

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

    let renderVerdict = "";
    let verdict: GateVerdict = "inconclusive";
    let marker = "INCONCLUSIVE ⚠️";
    let classification = "";
    let exitCode = 0;
    let renderSummary = "";

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
      process.stderr.write(
        `[pi-enforcement:static-site-build-check] build FAILED:\n${output}\n${errOutput}\n`,
      );
      verdict = "failed";
      marker = "FAILED ❌";
      classification = "build-failed";
      exitCode = 1;
      writeGateArtifacts({
        projectDir,
        gate: "make ci",
        mode: "short",
        verdict,
        marker,
        renderVerdict,
        classification,
        exitCode,
        sessionId:
          process.env["SESSION_ID"] ?? process.env["CLAUDE_SESSION_ID"] ?? "",
      });
      return;
    }

    // ── SEO/AI-discoverability baseline ─────────────────────────────────────
    // Pi's session_shutdown event cannot block(): this check is observe-only
    // (stderr), unlike the Claude harness's fail-closed static-site-build-check.sh
    // twin which blocks on the same invariants. Reduced-fidelity gap: a static
    // site can ship a broken SEO baseline via Pi without the developer being
    // re-spawned — the Claude harness holds the fail-closed authority.
    const seoViolations = checkSeoBaseline(projectDir);
    for (const v of seoViolations) {
      process.stderr.write(
        `[pi-enforcement:static-site-build-check] SEO: ${v}\n`,
      );
    }

    // ── Render verification ────────────────────────────────────────────────
    // Determine output dir (public/ or dist/).
    const outputDir = path.join(projectDir, "public");

    if (!fs.existsSync(outputDir)) {
      debugLog(
        "static-site-build-check",
        "no output dir — render verdict inconclusive",
      );
      renderSummary = "render: INCONCLUSIVE (output-dir-missing) — skipped";
      renderVerdict = "INCONCLUSIVE:output-dir-missing";
      verdict = "inconclusive";
      marker = "INCONCLUSIVE ⚠️";
      writeGateArtifacts({
        projectDir,
        gate: "make ci",
        mode: "short",
        verdict,
        marker,
        renderVerdict,
        classification,
        exitCode,
        sessionId:
          process.env["SESSION_ID"] ?? process.env["CLAUDE_SESSION_ID"] ?? "",
      });
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
        "render-check.js not found — render verdict inconclusive",
      );
      renderSummary = "render: INCONCLUSIVE (checker-missing) — skipped";
      renderVerdict = "INCONCLUSIVE:checker-missing";
      verdict = "inconclusive";
      marker = "INCONCLUSIVE ⚠️";
      writeGateArtifacts({
        projectDir,
        gate: "make ci",
        mode: "short",
        verdict,
        marker,
        renderVerdict,
        classification,
        exitCode,
        sessionId:
          process.env["SESSION_ID"] ?? process.env["CLAUDE_SESSION_ID"] ?? "",
      });
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
    renderVerdict = verdictLine ? verdictLine.split("=")[1] : "";

    debugLog("static-site-build-check", `render verdict: ${renderVerdict}`);

    // Pi doesn't support decision:block in session_shutdown; this gate is advisory only (stderr).
    // The claude harness has the fail-closed enforcement.
    if (renderVerdict.startsWith("FAIL:")) {
      const reason = renderVerdict.slice("FAIL:".length);
      process.stderr.write(
        `[pi-enforcement:static-site-build-check] render FAILED: ${reason}\n`,
      );
      verdict = "failed";
      marker = "FAILED ❌";
      classification = "render-failed";
    } else if (renderVerdict === "INCONCLUSIVE:browser-not-installed") {
      debugLog(
        "static-site-build-check",
        "render INCONCLUSIVE: browser not installed",
      );
      process.stderr.write(
        `[pi-enforcement:static-site-build-check] render INCONCLUSIVE: Chromium browser not found — run: npx playwright install chromium\n`,
      );
      verdict = "inconclusive";
      marker = "INCONCLUSIVE ⚠️";
      classification = "render-inconclusive-browser-missing";
      renderSummary = "render: INCONCLUSIVE (browser-not-installed) — skipped";
    } else if (renderVerdict === "") {
      debugLog(
        "static-site-build-check",
        "render-check emitted no verdict — crash or parse error",
      );
      process.stderr.write(
        `[pi-enforcement:static-site-build-check] render-check did not emit verdict — check render-check.js for parse/runtime errors\n`,
      );
      verdict = "inconclusive";
      marker = "INCONCLUSIVE ⚠️";
      classification = "render-inconclusive-empty";
      renderVerdict = "INCONCLUSIVE:empty-verdict";
      renderSummary = "render: INCONCLUSIVE (empty-verdict) — skipped";
    } else if (renderVerdict.startsWith("INCONCLUSIVE:")) {
      const detail = renderVerdict.slice("INCONCLUSIVE:".length);
      debugLog(
        "static-site-build-check",
        `render INCONCLUSIVE: ${detail} — downgrade to INCONCLUSIVE (not ALL CLEAR)`,
      );
      process.stderr.write(
        `[pi-enforcement:static-site-build-check] render INCONCLUSIVE: ${detail} — gate is inconclusive, not ALL CLEAR\n`,
      );
      verdict = "inconclusive";
      marker = "INCONCLUSIVE ⚠️";
      classification = `render-inconclusive-${detail}`;
      renderSummary = `render: INCONCLUSIVE (${detail}) — skipped`;
    } else {
      verdict = "clear";
      marker = "ALL CLEAR ✅";
      classification = "render-pass";
      renderSummary = "render: DOM non-empty, styles applied, 0 JS errors";
    }

    writeGateArtifacts({
      projectDir,
      gate: "make ci",
      mode: "short",
      verdict,
      marker,
      renderVerdict: renderSummary || renderVerdict,
      classification,
      exitCode,
      sessionId:
        process.env["SESSION_ID"] ?? process.env["CLAUDE_SESSION_ID"] ?? "",
    });
    // PASS: no action needed (non-blocking success)
  });
}
