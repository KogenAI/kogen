#!/usr/bin/env node
/**
 * phoenix-server.js — shared Phoenix server lifecycle helpers.
 *
 * Provides: allocFreePort, startPhoenixServer, waitForHttp200, stopPhoenixServer
 *
 * Required by render-check.js (--spawn mode) and test_harness/bench/screenshot.js.
 */

"use strict";

const net = require("net");
const http = require("http");
const { spawn } = require("child_process");

/**
 * Allocates a free TCP port by briefly binding to port 0 and reading back the
 * OS-assigned port, then immediately closing the socket.
 */
function allocFreePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.unref();
    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

/**
 * Spawns `mix phx.server` in a new process group so we can kill the entire
 * group (including child Erlang VMs) on cleanup.
 *
 * Returns the child process handle. Pipes stdout/stderr to process.stderr with
 * a `[phx]` prefix so logs are visible during debugging.
 */
function startPhoenixServer(cwd, port) {
  // Pre-build assets (non-watch) so the first HTTP request finds compiled
  // /assets/css/app.css and /assets/js/app.js on disk. mix phx.server's dev
  // watchers build assets AFTER boot; without this, waitForHttp200 resolves on
  // the first HTML 200 before the watcher's first asset build finishes →
  // Chromium hits a 404 on the bundle → render-check FAIL:asset-404.
  try {
    require("child_process").execFileSync("mix", ["assets.build"], {
      cwd,
      env: { ...process.env, MIX_ENV: "dev" },
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 120_000,
    });
  } catch (err) {
    // Non-fatal: if assets.build is absent or fails, fall through to spawn.
    // The dev watcher will still build assets; this only removes the cold-start race.
    process.stderr.write(
      "[phx] assets.build pre-build skipped/failed (non-fatal): " +
        (err.message || String(err)) +
        "\n",
    );
  }

  const child = spawn("mix", ["phx.server"], {
    cwd,
    detached: true,
    env: { ...process.env, PORT: String(port), MIX_ENV: "dev" },
    stdio: ["ignore", "pipe", "pipe"],
  });

  child.stdout.on("data", (data) => {
    process.stderr.write("[phx] " + data.toString());
  });
  child.stderr.on("data", (data) => {
    process.stderr.write("[phx] " + data.toString());
  });

  return child;
}

/**
 * Polls http://localhost:<port>/ until it responds with a 2xx/3xx status or
 * timeoutMs elapses. Treats ECONNREFUSED as "not ready yet" and retries every
 * 200ms. Rejects on timeout.
 */
function waitForHttp200(port, timeoutMs) {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + timeoutMs;

    function attempt() {
      // Per-attempt guard: the setTimeout below calls req.destroy(), which
      // emits an "error" event ("socket hang up" / ECONNRESET). That is a
      // self-inflicted abort, not a real failure — it must retry, not reject.
      // Without this flag a slow cold-start first request (Phoenix warmup
      // exceeding 1000ms) rejects the whole poll and aborts the screenshot.
      let aborted = false;
      const req = http.get(`http://localhost:${port}/`, (res) => {
        if (res.statusCode >= 200 && res.statusCode < 400) {
          res.resume();
          resolve();
        } else {
          res.resume();
          retry();
        }
      });
      req.on("error", (err) => {
        if (aborted || err.code === "ECONNREFUSED") {
          retry();
        } else {
          reject(err);
        }
      });
      req.setTimeout(1000, () => {
        aborted = true;
        req.destroy();
        retry();
      });
    }

    function retry() {
      if (Date.now() >= deadline) {
        reject(
          new Error(`Phoenix server did not respond within ${timeoutMs}ms`),
        );
        return;
      }
      setTimeout(attempt, 200);
    }

    attempt();
  });
}

/**
 * Stops the Phoenix server by killing its process group (negative PID).
 * Sends SIGTERM first, waits 2s, then SIGKILL. Treats ESRCH as success
 * (process already exited).
 */
async function stopPhoenixServer(child) {
  const pgid = child.pid;
  if (!pgid) return;

  function killGroup(signal) {
    try {
      process.kill(-pgid, signal);
    } catch (err) {
      if (err.code !== "ESRCH") {
        process.stderr.write(
          `[screenshot] stopPhoenixServer ${signal} error: ${err.message}\n`,
        );
      }
    }
  }

  killGroup("SIGTERM");
  await new Promise((resolve) => setTimeout(resolve, 2000));
  killGroup("SIGKILL");
}

module.exports = {
  allocFreePort,
  startPhoenixServer,
  waitForHttp200,
  stopPhoenixServer,
};
