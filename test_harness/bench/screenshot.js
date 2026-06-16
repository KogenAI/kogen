#!/usr/bin/env node
/**
 * Capture a full-page PNG screenshot of a built static site.
 *
 * Usage:
 *   node screenshot.js --cwd <dir> --stack <stack> --out <out.png>
 *
 * Stack-to-serve-dir mapping:
 *   static → builds (if needed) and serves public/
 *
 * Exit 0 on success, 1 on failure.
 */

"use strict";

const path = require("path");
const fs = require("fs");
const http = require("http");
const { execSync } = require("child_process");
const { chromium } = require("playwright");

const {
  allocFreePort,
  startPhoenixServer,
  waitForHttp200,
  stopPhoenixServer,
} = require("../../harnesses/claude/hooks/lib/phoenix-server.js");

const TIMEOUT_MS = 45_000;

const VISIBILITY_STYLESHEET = `
  body {
    color: inherit;
  }
  * {
    background-blend-mode: normal !important;
  }
  button, input, select, textarea, [role="button"] {
    background-color: #f5f5f5 !important;
    border: 1px solid #d0d0d0 !important;
    color: #000000 !important;
  }
  a {
    color: #0066cc !important;
  }
`;

/**
 * Returns true if the first 4KB of HTML contains a reference to a built/hashed
 * bundle script (e.g. /assets/index-UV0H7q2h.js). Distinguishes built output
 * from Vite source HTML that only contains /src/main.jsx-style imports.
 */
function hasBundledScript(html) {
  const snippet = html.slice(0, 4096);
  // Match <script src="..."> where the src resolves to a built asset:
  //   /assets/<any>.js or /assets/<any>.mjs  (Vite default outDir: assets)
  //   /dist/<any>.js
  //   any path containing a content-hash segment: filename.<hash>.(js|mjs)
  return /<script[^>]+src=["'](\/assets\/[^"']+|\/dist\/[^"']+|[^"']*\.\w+\.(js|mjs))["']/i.test(
    snippet,
  );
}

function parseArgs(argv) {
  const args = {};
  for (let i = 2; i < argv.length; i++) {
    const [key, ...rest] = argv[i].split("=");
    if (key.startsWith("--")) {
      const name = key.slice(2);
      const value = rest.length > 0 ? rest.join("=") : argv[++i];
      args[name] = value;
    }
  }
  return args;
}

function runBuild(cmd, args, cwd) {
  process.stderr.write(
    `[screenshot] running: ${cmd} ${args.join(" ")} in ${cwd}\n`,
  );
  try {
    const result = execSync(`${cmd} ${args.join(" ")}`, {
      cwd,
      timeout: TIMEOUT_MS,
      stdio: ["ignore", "pipe", "pipe"],
    });
    process.stderr.write(
      `[screenshot] build stdout: ${result ? result.toString().slice(0, 500) : "(none)"}\n`,
    );
  } catch (err) {
    const stdout = err.stdout ? err.stdout.toString().slice(0, 1000) : "";
    const stderr = err.stderr ? err.stderr.toString().slice(0, 1000) : "";
    throw new Error(
      `Build command failed: ${cmd} ${args.join(" ")}\nstdout: ${stdout}\nstderr: ${stderr}\nexit: ${err.status}`,
    );
  }
}

function resolveServeDir(cwd, stack) {
  process.stderr.write(
    `[screenshot] resolveServeDir: cwd=${cwd} stack=${stack}\n`,
  );

  switch (stack) {
    case "static": {
      const publicDir = path.join(cwd, "public");

      // Already-built: public/index.html with a bundled script → serve directly.
      if (fs.existsSync(path.join(publicDir, "index.html"))) {
        const publicHtml = fs
          .readFileSync(path.join(publicDir, "index.html"), "utf-8")
          .slice(0, 4096);
        if (hasBundledScript(publicHtml)) {
          process.stderr.write(
            `[screenshot] static → found public/index.html with bundle marker, serving public/\n`,
          );
          return publicDir;
        }
      }

      // Build needed — public/ absent or stale (no bundle marker).
      process.stderr.write(
        `[screenshot] static → running npm install + build\n`,
      );
      runBuild("npm", ["install", "--silent", "--no-audit", "--no-fund"], cwd);
      runBuild("npm", ["run", "build"], cwd);
      if (fs.existsSync(path.join(publicDir, "index.html"))) {
        return publicDir;
      }
      throw new Error(
        `Vite build ran but public/index.html not found in ${cwd}`,
      );
    }

    default: {
      throw new Error(`Unknown stack: ${stack}`);
    }
  }
}

function startServer(serveDir, port) {
  return new Promise((resolve, reject) => {
    const server = http.createServer((req, res) => {
      const urlPath = req.url === "/" ? "/index.html" : req.url;
      // Strip query strings
      const cleanPath = urlPath.split("?")[0];
      const filePath = path.join(serveDir, cleanPath);

      fs.readFile(filePath, (err, data) => {
        if (err) {
          res.writeHead(404);
          res.end("Not found");
          return;
        }

        const ext = path.extname(filePath).toLowerCase();
        const mimeTypes = {
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
          ".eot": "application/vnd.ms-fontobject",
        };
        const contentType = mimeTypes[ext] || "application/octet-stream";

        res.writeHead(200, { "Content-Type": contentType });
        res.end(data);
      });
    });

    server.on("error", reject);
    server.listen(port, "127.0.0.1", () => resolve(server));
  });
}

/**
 * Opens a Chromium browser, navigates to `url`, injects visibility styles,
 * and captures a full-page PNG to `outPath`. Used by both static and Phoenix
 * screenshot flows.
 */
async function captureAtUrl(url, outPath) {
  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage();

    // Collect JS errors from the page
    const jsErrors = [];
    page.on("pageerror", (err) => {
      jsErrors.push(err.message);
    });
    page.on("console", (msg) => {
      if (msg.type() === "error") {
        jsErrors.push("[console.error] " + msg.text());
      }
    });

    await page.setViewportSize({ width: 1280, height: 720 });
    process.stderr.write(`[screenshot] navigating to: ${url}\n`);
    await page.goto(url, { timeout: 15_000 });
    await page
      .waitForLoadState("networkidle", { timeout: 15_000 })
      .catch(() => {
        // Non-fatal: some pages may not reach networkidle; proceed anyway.
      });
    // Non-fatal wait for SPA mount — gives React/Vue one more frame to populate #root/#app.
    await page
      .waitForFunction(
        () => {
          const root = document.querySelector("#root, #app");
          return root && root.children.length > 0;
        },
        { timeout: 5000 },
      )
      .catch(() => {
        process.stderr.write(
          "[screenshot] waitForFunction TIMEOUT: #root/#app still empty after 5000ms\n",
        );
      });

    // Log current #root children count at screenshot time
    const rootInfo = await page.evaluate(() => {
      const root = document.querySelector("#root");
      const app = document.querySelector("#app");
      const target = root || app;
      if (!target)
        return { found: false, selector: null, childCount: 0, innerHTML: "" };
      return {
        found: true,
        selector: root ? "#root" : "#app",
        childCount: target.children.length,
        innerHTML: target.innerHTML.slice(0, 200),
      };
    });
    process.stderr.write(
      "[screenshot] root element: found=" +
        rootInfo.found +
        " selector=" +
        rootInfo.selector +
        " childCount=" +
        rootInfo.childCount +
        "\n",
    );
    if (rootInfo.found) {
      process.stderr.write(
        "[screenshot] root innerHTML (first 200 chars): " +
          rootInfo.innerHTML +
          "\n",
      );
    }

    // Report any JS errors collected during page load
    if (jsErrors.length > 0) {
      process.stderr.write(
        "[screenshot] JS errors detected (" + jsErrors.length + "):\n",
      );
      jsErrors.forEach((e, i) => {
        process.stderr.write("  [" + (i + 1) + "] " + e + "\n");
      });
    } else {
      process.stderr.write("[screenshot] no JS errors detected\n");
    }

    // Always inject visibility styles to ensure SPA content shows up in screenshots
    process.stderr.write(`[screenshot] injecting visibility styles\n`);
    try {
      await page.addStyleTag({ content: VISIBILITY_STYLESHEET });
      // Brief pause for styles to render
      await new Promise((resolve) => setTimeout(resolve, 100));
    } catch (err) {
      // If CSS injection fails (CSP or other), log but continue
      process.stderr.write(
        `[screenshot] failed to inject styles (non-fatal): ${err.message}\n`,
      );
    }
    process.stderr.write(`[screenshot] capturing screenshot to: ${outPath}\n`);
    await page.screenshot({ path: outPath, fullPage: true });
    process.stderr.write(`[screenshot] done\n`);
  } finally {
    await browser.close();
  }
}

async function main() {
  const args = parseArgs(process.argv);

  const cwd = args.cwd;
  const stack = args.stack;
  const outPath = args.out;

  if (!cwd || !stack || !outPath) {
    process.stderr.write(
      "Usage: node screenshot.js --cwd <dir> --stack <stack> --out <out.png>\n",
    );
    process.exit(1);
  }

  if (!fs.existsSync(cwd)) {
    process.stderr.write(`cwd does not exist: ${cwd}\n`);
    process.exit(1);
  }

  fs.mkdirSync(path.dirname(outPath), { recursive: true });

  // ── Phoenix: own server lifecycle, no static serveDir ──────────────────────
  if (stack === "phoenix") {
    let port;
    try {
      port = await allocFreePort();
    } catch (err) {
      process.stderr.write(`Failed to allocate free port: ${err.message}\n`);
      process.exit(1);
    }
    process.stderr.write(`[screenshot] Phoenix: allocated port ${port}\n`);

    process.stderr.write(`[screenshot] Phoenix: running mix deps.get\n`);
    try {
      execSync("mix deps.get", { cwd, timeout: 60_000, stdio: "pipe" });
    } catch (err) {
      const stderr = err.stderr ? err.stderr.toString().slice(0, 1000) : "";
      process.stderr.write(`[screenshot] mix deps.get failed: ${stderr}\n`);
      process.exit(1);
    }

    process.stderr.write(`[screenshot] Phoenix: running mix compile\n`);
    try {
      execSync("mix compile", { cwd, timeout: 90_000, stdio: "pipe" });
    } catch (err) {
      const stderr = err.stderr ? err.stderr.toString().slice(0, 1000) : "";
      process.stderr.write(`[screenshot] mix compile failed: ${stderr}\n`);
      process.exit(1);
    }

    const child = startPhoenixServer(cwd, port);

    // Register safety-net cleanup before the try block so it fires even on
    // uncaught exceptions during the screenshot phase.
    process.on("exit", () => {
      try {
        process.kill(-child.pid, "SIGKILL");
      } catch (_) {
        // ESRCH = already exited; ignore.
      }
    });

    try {
      process.stderr.write(
        `[screenshot] Phoenix: waiting for HTTP 200 on port ${port}\n`,
      );
      await waitForHttp200(port, 30_000);
      process.stderr.write(`[screenshot] Phoenix: server ready\n`);

      await captureAtUrl(`http://localhost:${port}/`, outPath);
    } finally {
      process.stderr.write(`[screenshot] Phoenix: stopping server\n`);
      await stopPhoenixServer(child);
      process.stderr.write(`[screenshot] Phoenix: server stopped\n`);
    }
    return;
  }

  // ── Static stacks: resolve serve dir, start Node HTTP server ───────────────
  let serveDir;
  try {
    serveDir = resolveServeDir(cwd, stack);
  } catch (err) {
    process.stderr.write(`Failed to resolve serve dir: ${err.message}\n`);
    process.exit(1);
  }

  process.stderr.write(`[screenshot] serveDir resolved to: ${serveDir}\n`);

  const indexPath = path.resolve(serveDir, "index.html");
  process.stderr.write(
    `[screenshot] checking for index.html at: ${indexPath}\n`,
  );
  if (!fs.existsSync(indexPath)) {
    // List directory contents to aid debugging
    try {
      const entries = fs.readdirSync(serveDir);
      process.stderr.write(
        `[screenshot] contents of ${serveDir}: ${entries.join(", ")}\n`,
      );
    } catch (_) {
      process.stderr.write(`[screenshot] could not list ${serveDir}\n`);
    }
    process.stderr.write(`index.html not found at: ${indexPath}\n`);
    process.exit(1);
  }
  process.stderr.write(`[screenshot] index.html found, launching browser\n`);

  process.stderr.write(
    `[screenshot] starting HTTP server on dynamic port serving ${serveDir}\n`,
  );
  let server;
  try {
    server = await startServer(serveDir, 0);
  } catch (err) {
    process.stderr.write(`Failed to start HTTP server: ${err.message}\n`);
    process.exit(1);
  }

  const actualPort = server.address().port;
  process.stderr.write(
    `[screenshot] HTTP server bound to port ${actualPort}\n`,
  );

  try {
    await captureAtUrl(`http://localhost:${actualPort}/`, outPath);
  } finally {
    server.close();
  }
}

main().catch((err) => {
  process.stderr.write(`screenshot.js error: ${err.message}\n${err.stack}\n`);
  process.exit(1);
});
