#!/usr/bin/env node
/**
 * render-check.js — headless Chromium render verification engine.
 *
 * Usage:
 *   node render-check.js --mode static [--timeout 30000] <built-output-dir>
 *   node render-check.js --mode phoenix [--port 4000] [--timeout 30000]
 *
 * Outputs a single line to stdout:
 *   RENDER_VERDICT=PASS
 *   RENDER_VERDICT=FAIL:<reason>
 *   RENDER_VERDICT=INCONCLUSIVE:<reason>
 *
 * FAIL reasons:    empty-dom | empty-content-region | unstyled | js-error:<detail> | asset-404:<url>
 * INCONCLUSIVE:    chromium-launch-failed | playwright-module-unresolvable | server-unready | timeout | config-error | <other>
 *
 * Exit 0 always — verdict is communicated via the RENDER_VERDICT line.
 * Diagnostic messages go to stderr.
 */

"use strict";

const path = require("path");
const fs = require("fs");
const http = require("http");
const {
  allocFreePort,
  startPhoenixServer,
  waitForHttp200,
  stopPhoenixServer,
} = require("./phoenix-server.js");

const DEFAULT_TIMEOUT_MS = 30_000;
const PHOENIX_READINESS_MS = 20_000;

// ── Argument parsing ─────────────────────────────────────────────────────────

function parseArgs(argv) {
  const args = { timeout: DEFAULT_TIMEOUT_MS, port: 4000 };
  for (let i = 2; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--mode") {
      args.mode = argv[++i];
    } else if (arg === "--port") {
      args.port = parseInt(argv[++i], 10);
    } else if (arg === "--timeout") {
      args.timeout = parseInt(argv[++i], 10);
    } else if (arg === "--spawn") {
      args.spawn = argv[++i];
    } else if (!arg.startsWith("--")) {
      args.outputDir = arg;
    }
  }
  return args;
}

// ── Verdict helpers ──────────────────────────────────────────────────────────

function verdict(v) {
  process.stdout.write(`RENDER_VERDICT=${v}\n`);
  process.exit(0);
}

function log(msg) {
  process.stderr.write(`[render-check] ${msg}\n`);
}

// ── Static HTTP server ───────────────────────────────────────────────────────

const MIME = {
  ".html": "text/html",
  ".js": "application/javascript",
  ".mjs": "application/javascript",
  ".css": "text/css",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
  ".json": "application/json",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".ttf": "font/ttf",
};

function startServer(serveDir, port) {
  return new Promise((resolve, reject) => {
    const server = http.createServer((req, res) => {
      const urlPath = req.url === "/" ? "/index.html" : req.url.split("?")[0];
      const filePath = path.join(serveDir, urlPath);
      fs.readFile(filePath, (err, data) => {
        if (err) {
          res.writeHead(404);
          res.end("Not found");
          return;
        }
        const ext = path.extname(filePath).toLowerCase();
        res.writeHead(200, {
          "Content-Type": MIME[ext] || "application/octet-stream",
        });
        res.end(data);
      });
    });
    server.on("error", reject);
    server.listen(port, "127.0.0.1", () => resolve(server));
  });
}

// ── Render checks via Playwright ─────────────────────────────────────────────

async function runChecks(url, timeoutMs, mode) {
  let chromium;
  try {
    // Resolve playwright from an ordered list of boundary-clean candidates:
    // (1) CODEGEN_DIR/node_modules, (2) repo root derived from __dirname
    // (render-check.js lives at harnesses/claude/hooks/lib/ → four dirs up
    // is the repo root), (3) node's default resolution. First hit wins.
    const candidates = [];
    const codegenDir = process.env["CODEGEN_DIR"];
    if (codegenDir) {
      candidates.push(path.join(codegenDir, "node_modules", "playwright"));
    }
    candidates.push(
      path.join(
        __dirname,
        "..",
        "..",
        "..",
        "..",
        "node_modules",
        "playwright",
      ),
    );
    candidates.push("playwright");

    let resolved = false;
    for (const candidate of candidates) {
      try {
        ({ chromium } = require(candidate));
        resolved = true;
        break;
      } catch (_e) {
        // try next candidate
      }
    }
    if (!resolved) {
      throw new Error("playwright not resolvable from any candidate path");
    }
  } catch (_e) {
    const codegenDir = process.env["CODEGEN_DIR"] || "(unset)";
    const fourUp = path.join(
      __dirname,
      "..",
      "..",
      "..",
      "..",
      "node_modules",
      "playwright",
    );
    log(
      `playwright module unresolvable — path/env fault, not a missing browser binary. ` +
        `Candidates tried: CODEGEN_DIR=${codegenDir}/node_modules/playwright, ` +
        `four-up=${fourUp}, node-default=playwright. ` +
        `Verify lib/render-check.js sits beside the hook and node_modules/playwright is resolvable.`,
    );
    verdict("INCONCLUSIVE:playwright-module-unresolvable");
    return;
  }

  let browser;
  try {
    browser = await chromium.launch({ headless: true });
  } catch (e) {
    log(`chromium launch failed: ${e.message}`);
    verdict("INCONCLUSIVE:chromium-launch-failed");
    return;
  }

  try {
    const page = await browser.newPage();
    const jsErrors = [];
    const failedAssets = [];

    page.on("pageerror", (err) => {
      jsErrors.push(err.message);
    });
    page.on("console", (msg) => {
      if (msg.type() === "error") {
        jsErrors.push("[console.error] " + msg.text());
      }
    });
    page.on("response", (response) => {
      const status = response.status();
      const respUrl = response.url();
      // Only flag non-doc asset failures (css/js/fonts/images).
      if (
        status >= 400 &&
        respUrl !== url &&
        /\.(css|js|mjs|woff2?|ttf|eot|png|jpg|jpeg|gif|svg|ico)(\?|$)/i.test(
          respUrl,
        )
      ) {
        failedAssets.push(`${status}:${respUrl}`);
      }
    });

    await page.setViewportSize({ width: 1280, height: 720 });

    log(`navigating to ${url}`);
    try {
      await page.goto(url, { timeout: timeoutMs });
    } catch (e) {
      log(`navigation timeout/error: ${e.message}`);
      verdict("INCONCLUSIVE:timeout");
      return;
    }

    // Wait for network idle; non-fatal.
    await page
      .waitForLoadState("networkidle", { timeout: Math.min(timeoutMs, 10_000) })
      .catch(() => {
        log("networkidle timeout — proceeding");
      });

    // Give SPA one extra tick to mount.
    await page
      .waitForFunction(
        () => {
          const root = document.querySelector("#root, #app");
          return root && root.children.length > 0;
        },
        { timeout: 5000 },
      )
      .catch(() => {
        log("SPA mount wait expired — proceeding");
      });

    // ── Check 1: non-empty DOM ───────────────────────────────────────────────
    const domInfo = await page.evaluate(() => {
      const root = document.querySelector("#root, #app");
      if (root) {
        return {
          selector: root.id ? "#" + root.id : root.tagName,
          childCount: root.children.length,
        };
      }
      // Fall back to body child count.
      const body = document.body;
      const visibleChildren = body
        ? Array.from(body.children).filter((el) => {
            const s = window.getComputedStyle(el);
            return s.display !== "none" && s.visibility !== "hidden";
          }).length
        : 0;
      return { selector: "body", childCount: visibleChildren };
    });

    log(
      `DOM check: selector=${domInfo.selector} children=${domInfo.childCount}`,
    );

    if (domInfo.childCount === 0) {
      verdict(`FAIL:empty-dom`);
      return;
    }

    // ── Check 1b: non-empty content region (phoenix only) ────────────────────
    // A rendered layout shell can hide a blank content area — tests that assert
    // only shell fragments pass while the page renders empty. Probe the primary
    // content region; fail if it is present but near-empty.
    if (mode === "phoenix") {
      const regionInfo = await page.evaluate(() => {
        const selectors = ["[data-render-region]", "main", ".flex-1"];
        for (const sel of selectors) {
          const el = document.querySelector(sel);
          if (el) {
            return {
              selector: sel,
              textLen: (el.innerText || "").trim().length,
              childCount: el.childElementCount,
            };
          }
        }
        return null;
      });
      if (regionInfo) {
        log(
          `content region: selector=${regionInfo.selector} textLen=${regionInfo.textLen} children=${regionInfo.childCount}`,
        );
        if (regionInfo.textLen < 50 && regionInfo.childCount < 2) {
          verdict(`FAIL:empty-content-region`);
          return;
        }
      }
    }

    // ── Check 2: styles applied ──────────────────────────────────────────────
    const styleInfo = await page.evaluate(() => {
      // Count non-injected (author) stylesheet rules.
      let authorRules = 0;
      for (const sheet of Array.from(document.styleSheets)) {
        try {
          // Skip injected (inline) sheets — those come from JS and may exist even
          // when no author CSS loaded. Injected sheets lack an href.
          if (!sheet.href) continue;
          authorRules += sheet.cssRules ? sheet.cssRules.length : 0;
        } catch (_) {
          // Cross-origin sheet — counts as present.
          authorRules += 1;
        }
      }

      const body = document.body;
      let bodyMargin = "0px";
      let bodyFontFamily = "";
      if (body) {
        const cs = window.getComputedStyle(body);
        bodyMargin = cs.margin;
        bodyFontFamily = cs.fontFamily;
      }

      return { authorRules, bodyMargin, bodyFontFamily };
    });

    log(
      `style check: authorRules=${styleInfo.authorRules} margin=${styleInfo.bodyMargin} font=${styleInfo.bodyFontFamily}`,
    );

    // UA-default: 8px margin all sides (Chrome), serif font.
    const uaMarginPattern = /^8px/;
    const uaFontPattern = /\bserif\b/i;
    const hasUaMargin = uaMarginPattern.test(styleInfo.bodyMargin);
    const hasUaFont = uaFontPattern.test(styleInfo.bodyFontFamily);

    if (styleInfo.authorRules === 0 && hasUaMargin && hasUaFont) {
      verdict("FAIL:unstyled");
      return;
    }

    // ── Check 3: JS errors / failed assets ──────────────────────────────────
    if (failedAssets.length > 0) {
      const first = failedAssets[0];
      verdict(`FAIL:asset-404:${first}`);
      return;
    }

    if (jsErrors.length > 0) {
      const detail = jsErrors[0].slice(0, 120).replace(/\n/g, " ");
      verdict(`FAIL:js-error:${detail}`);
      return;
    }

    verdict("PASS");
  } finally {
    if (browser) {
      await browser.close().catch(() => {});
    }
  }
}

// ── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  const args = parseArgs(process.argv);

  if (!args.mode) {
    log("--mode required (static|phoenix)");
    verdict("INCONCLUSIVE:config-error");
    return;
  }

  const timeoutMs = args.timeout;

  if (args.mode === "static") {
    const outputDir = args.outputDir;
    if (!outputDir || !fs.existsSync(outputDir)) {
      log(`output dir not found: ${outputDir}`);
      verdict("INCONCLUSIVE:config-error");
      return;
    }

    const indexPath = path.join(outputDir, "index.html");
    if (!fs.existsSync(indexPath)) {
      log(`index.html not found in ${outputDir}`);
      verdict("INCONCLUSIVE:config-error");
      return;
    }

    let port;
    try {
      port = await allocFreePort();
    } catch (e) {
      log(`port alloc failed: ${e.message}`);
      verdict("INCONCLUSIVE:config-error");
      return;
    }

    let server;
    try {
      server = await startServer(outputDir, port);
    } catch (e) {
      log(`server start failed: ${e.message}`);
      verdict("INCONCLUSIVE:config-error");
      return;
    }

    log(`static server on port ${port} serving ${outputDir}`);

    try {
      await runChecks(`http://localhost:${port}/`, timeoutMs, "static");
    } finally {
      server.close();
    }
  } else if (args.mode === "phoenix") {
    if (args.spawn) {
      // --spawn <cwd>: boot mix phx.server ourselves, then run checks
      let port;
      try {
        port = await allocFreePort();
      } catch (e) {
        log(`port alloc failed: ${e.message}`);
        verdict("INCONCLUSIVE:config-error");
        return;
      }

      const child = startPhoenixServer(args.spawn, port);
      try {
        try {
          await waitForHttp200(port, PHOENIX_READINESS_MS);
        } catch (_e) {
          log(`phoenix server did not start in ${args.spawn}`);
          verdict("INCONCLUSIVE:server-unready");
          return;
        }
        await runChecks(`http://localhost:${port}/`, timeoutMs, "phoenix");
      } finally {
        await stopPhoenixServer(child);
      }
    } else {
      // --port <N>: assume server already running
      const port = args.port;
      log(`phoenix mode: checking readiness on port ${port}`);

      try {
        await waitForHttp200(port, PHOENIX_READINESS_MS);
      } catch (_e) {
        log(`phoenix server not ready on port ${port}`);
        verdict("INCONCLUSIVE:server-unready");
        return;
      }

      await runChecks(`http://localhost:${port}/`, timeoutMs, "phoenix");
    }
  } else {
    log(`unknown mode: ${args.mode}`);
    verdict("INCONCLUSIVE:config-error");
  }
}

main().catch((e) => {
  log(`unhandled error: ${e.message}`);
  // A crash reaching this top-level handler is a checker bug (unhandled
  // rejection/exception), not a real navigation timeout — mislabeling it
  // INCONCLUSIVE:timeout hides checker defects behind flaky-looking output.
  // Exit non-zero so the crash is distinguishable from the normal exit-0
  // verdict path (callers already parse stdout and ignore exit code via
  // `|| true`, so this does not change existing gate wiring).
  process.stdout.write("RENDER_VERDICT=INCONCLUSIVE:checker-error\n");
  process.exitCode = 1;
});
