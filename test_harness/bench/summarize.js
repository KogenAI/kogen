#!/usr/bin/env node
/**
 * Aggregate benchmark JSONL records into a Markdown summary.
 *
 * Usage:
 *   node summarize.js <BENCH_RUN_DIR>
 *
 * Reads:  <BENCH_RUN_DIR>/runs/<harness>/<stack>/*.jsonl  (last harness_summary line)
 * Reads:  <BENCH_RUN_DIR>/manifest.json
 * Writes: <BENCH_RUN_DIR>/summary.md
 */

"use strict";

const fs = require("fs");
const path = require("path");

// ---------------------------------------------------------------------------
// CLI validation
// ---------------------------------------------------------------------------

const runDir = process.argv[2];
if (!runDir) {
  process.stderr.write("Usage: node summarize.js <BENCH_RUN_DIR>\n");
  process.exit(1);
}
if (!fs.existsSync(runDir) || !fs.statSync(runDir).isDirectory()) {
  process.stderr.write(`Error: not a directory: ${runDir}\n`);
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Return a finite number, or null for ":unknown" / non-numeric values. */
function num(v) {
  if (v === undefined || v === null || v === ":unknown") return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

function fmtUSD(n) {
  return n == null ? "—" : "$" + n.toFixed(6);
}
function fmtInt(n) {
  return n == null ? "—" : n.toLocaleString();
}
function fmtMs(n) {
  return n == null ? "—" : n + " ms";
}
function pct(p, t) {
  return t ? ((100 * p) / t).toFixed(1) + "%" : "—";
}

/** Sum non-null num(r.parsed[key]) across records. Returns {total, count}. */
function sumKey(records, key) {
  let total = 0;
  let count = 0;
  for (const r of records) {
    const v = num(r.parsed[key]);
    if (v !== null) {
      total += v;
      count++;
    }
  }
  return { total, count };
}

function avgKey(records, key) {
  const { total, count } = sumKey(records, key);
  return count > 0 ? total / count : null;
}

// ---------------------------------------------------------------------------
// Load manifest
// ---------------------------------------------------------------------------

function loadManifest() {
  const manifestPath = path.join(runDir, "manifest.json");
  let manifest = {};
  if (fs.existsSync(manifestPath)) {
    try {
      manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
    } catch (_) {
      // tolerate parse errors
    }
  }
  const reasonPath = path.join(runDir, "reason.txt");
  let reason = manifest.reason || "";
  if (!reason && fs.existsSync(reasonPath)) {
    reason = fs.readFileSync(reasonPath, "utf8").trim();
  }
  return { manifest, reason };
}

// ---------------------------------------------------------------------------
// Collect records
// ---------------------------------------------------------------------------

function collectRecords() {
  const runsDir = path.join(runDir, "runs");
  const records = [];
  const screenshotCounts = {}; // "harness/stack" -> count

  if (!fs.existsSync(runsDir)) {
    return { records, screenshotCounts };
  }

  let harnesses;
  try {
    harnesses = fs.readdirSync(runsDir);
  } catch (_) {
    return { records, screenshotCounts };
  }

  for (const harness of harnesses) {
    const harnessDir = path.join(runsDir, harness);
    if (!fs.statSync(harnessDir).isDirectory()) continue;

    let stacks;
    try {
      stacks = fs.readdirSync(harnessDir);
    } catch (_) {
      continue;
    }

    for (const stack of stacks) {
      const stackDir = path.join(harnessDir, stack);
      if (!fs.statSync(stackDir).isDirectory()) continue;

      // Count screenshots once per stack dir
      const key = `${harness}/${stack}`;
      let pngCount = 0;
      try {
        const files = fs.readdirSync(stackDir);
        pngCount = files.filter((f) => f.endsWith(".png")).length;
      } catch (_) {}
      screenshotCounts[key] = pngCount;

      let files;
      try {
        files = fs.readdirSync(stackDir);
      } catch (_) {
        continue;
      }

      for (const file of files) {
        if (!file.endsWith(".jsonl")) continue;
        const filePath = path.join(stackDir, file);
        const testName = file.replace(/\.jsonl$/, "");

        let summaryLine = null;
        try {
          const content = fs.readFileSync(filePath, "utf8");
          const lines = content.split("\n").filter((l) => l.trim() !== "");
          for (const line of lines) {
            try {
              const obj = JSON.parse(line);
              if (obj.type === "harness_summary") {
                summaryLine = obj;
              }
            } catch (_) {}
          }
        } catch (_) {}

        if (summaryLine) {
          records.push({
            harness,
            stack,
            test: testName,
            exitCode: summaryLine.exit_code ?? -1,
            pass: summaryLine.assertion_passed === true,
            parsed: summaryLine.parsed || {},
          });
        } else {
          records.push({
            harness,
            stack,
            test: testName,
            exitCode: -1,
            pass: false,
            parsed: {},
          });
        }
      }
    }
  }

  return { records, screenshotCounts };
}

// ---------------------------------------------------------------------------
// Render sections
// ---------------------------------------------------------------------------

function renderMetadata(manifest, reason) {
  const startedAt = manifest.started_at || manifest.startedAt || "—";
  const sha = manifest.codegen_sha || manifest.sha || "—";
  const runDirName = path.basename(runDir);
  const hv = manifest.harness_versions || {};
  const claudeVer = hv.claude || "—";
  const piVer = hv.pi || "—";

  return [
    `# Benchmark Summary: ${runDirName}`,
    "",
    `| Field | Value |`,
    `| --- | --- |`,
    `| Date | ${startedAt} |`,
    `| SHA | ${sha} |`,
    `| Reason | ${reason || "—"} |`,
    `| Claude harness | ${claudeVer} |`,
    `| Pi harness | ${piVer} |`,
  ].join("\n");
}

function renderPassRate(records) {
  const byHarness = {};
  for (const r of records) {
    if (!byHarness[r.harness]) byHarness[r.harness] = { passed: 0, total: 0 };
    byHarness[r.harness].total++;
    if (r.pass) byHarness[r.harness].passed++;
  }

  const rows = Object.entries(byHarness)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([harness, { passed, total }]) => {
      return `| ${harness} | ${passed} | ${total} | ${pct(passed, total)} |`;
    });

  return [
    "## Pass Rate",
    "",
    "| Harness | Passed | Total | Rate |",
    "| --- | --- | --- | --- |",
    ...rows,
  ].join("\n");
}

function renderCostTable(records) {
  // Per-harness
  const byHarness = {};
  for (const r of records) {
    if (!byHarness[r.harness]) byHarness[r.harness] = [];
    byHarness[r.harness].push(r);
  }

  // Per-stack (across harnesses)
  const byStack = {};
  for (const r of records) {
    if (!byStack[r.stack]) byStack[r.stack] = [];
    byStack[r.stack].push(r);
  }

  const rows = [];

  for (const harness of Object.keys(byHarness).sort()) {
    const recs = byHarness[harness];
    const { total } = sumKey(recs, "cost_usd");
    const avg = avgKey(recs, "cost_usd");
    rows.push(`| harness: ${harness} | ${fmtUSD(total)} | ${fmtUSD(avg)} |`);
  }

  for (const stack of Object.keys(byStack).sort()) {
    const recs = byStack[stack];
    const { total } = sumKey(recs, "cost_usd");
    const avg = avgKey(recs, "cost_usd");
    rows.push(`| stack: ${stack} | ${fmtUSD(total)} | ${fmtUSD(avg)} |`);
  }

  // Grand total
  const { total: grandTotal } = sumKey(records, "cost_usd");
  const grandAvg = avgKey(records, "cost_usd");
  rows.push(
    `| **TOTAL** | **${fmtUSD(grandTotal)}** | **${fmtUSD(grandAvg)}** |`,
  );

  return [
    "## Cost",
    "",
    "| Scope | Total | Avg/test |",
    "| --- | --- | --- |",
    ...rows,
  ].join("\n");
}

function renderTokensTable(records) {
  const byHarness = {};
  for (const r of records) {
    if (!byHarness[r.harness]) byHarness[r.harness] = [];
    byHarness[r.harness].push(r);
  }

  const rows = Object.keys(byHarness)
    .sort()
    .map((harness) => {
      const recs = byHarness[harness];
      const inputTotal =
        sumKey(recs, "input_tokens").total +
        sumKey(recs, "cache_read_tokens").total +
        sumKey(recs, "cache_creation_tokens").total;
      const { total: outputTotal } = sumKey(recs, "output_tokens");
      return `| ${harness} | ${fmtInt(inputTotal)} | ${fmtInt(outputTotal)} |`;
    });

  return [
    "## Tokens",
    "",
    "_Input = input_tokens + cache_read_tokens + cache_creation_tokens_",
    "",
    "| Harness | Input | Output |",
    "| --- | --- | --- |",
    ...rows,
  ].join("\n");
}

function renderAverages(records) {
  function avg(recs, key) {
    const vals = recs.map((r) => num(r.parsed[key])).filter((v) => v != null);
    if (vals.length === 0) return null;
    return vals.reduce((a, b) => a + b, 0) / vals.length;
  }
  function fmtAvgSecs(recs, key) {
    const v = avg(recs, key);
    return v == null ? "—" : (v / 1000).toFixed(1) + "s";
  }
  function fmtAvgUSD(recs) {
    const v = avg(recs, "cost_usd");
    return v == null ? "—" : "$" + v.toFixed(3);
  }

  const harnesses = [...new Set(records.map((r) => r.harness))].sort();
  const header = `| Metric | ${harnesses.join(" | ")} |`;
  const sep = `| --- |${harnesses.map(() => " --- |").join("")}`;

  function row(label, fn) {
    return `| ${label} | ${harnesses.map((h) => fn(records.filter((r) => r.harness === h))).join(" | ")} |`;
  }

  const passed = (h) => records.filter((r) => r.harness === h && r.pass).length;
  const total = (h) => records.filter((r) => r.harness === h).length;

  return [
    "## Averages",
    "",
    header,
    sep,
    `| Pass rate | ${harnesses.map((h) => `${passed(h)}/${total(h)} (${total(h) === 0 ? "—" : ((passed(h) / total(h)) * 100).toFixed(1)}%)`).join(" | ")} |`,
    row("Avg cost/test", fmtAvgUSD),
    row("Avg build duration", (recs) => fmtAvgSecs(recs, "build_duration_ms")),
    row("Avg agent duration", (recs) => fmtAvgSecs(recs, "duration_ms")),
    row("Avg turns", (recs) => {
      const v = avg(recs, "num_turns");
      return v == null ? "—" : v.toFixed(1);
    }),
  ].join("\n");
}

function renderDurationTurns(records) {
  const sorted = records.slice().sort((a, b) => {
    const h = a.harness.localeCompare(b.harness);
    if (h !== 0) return h;
    const s = a.stack.localeCompare(b.stack);
    return s !== 0 ? s : a.test.localeCompare(b.test);
  });

  const rows = sorted.map((r) => {
    const agent = num(r.parsed.duration_ms);
    const build = num(r.parsed.build_duration_ms);
    const t = num(r.parsed.num_turns);
    return `| ${r.harness} | ${r.stack} | ${r.test} | ${fmtMs(build)} | ${fmtMs(agent)} | ${t == null ? "—" : t} |`;
  });

  return [
    "## Duration / Turns",
    "",
    "_Agent duration: LLM session wall-clock. Build duration: full pipeline including setup._",
    "_Pi records `:unknown` for agent duration/turns._",
    "",
    "| Harness | Stack | Test | Build Duration | Agent Duration | Turns |",
    "| --- | --- | --- | --- | --- | --- |",
    ...rows,
  ].join("\n");
}

function renderPerTestTable(records) {
  const sorted = records.slice().sort((a, b) => {
    const h = a.harness.localeCompare(b.harness);
    if (h !== 0) return h;
    const s = a.stack.localeCompare(b.stack);
    if (s !== 0) return s;
    return a.test.localeCompare(b.test);
  });

  const rows = sorted.map((r) => {
    const cost = num(r.parsed.cost_usd);
    const agentDur = num(r.parsed.duration_ms);
    const buildDur = num(r.parsed.build_duration_ms);
    const turns = num(r.parsed.num_turns);
    const passIcon = r.pass ? "✅" : "❌";
    return `| ${r.harness} | ${r.stack} | ${r.test} | ${fmtUSD(cost)} | ${fmtMs(agentDur)} | ${fmtMs(buildDur)} | ${turns == null ? "—" : turns} | ${passIcon} |`;
  });

  return [
    "## Per-Test Results",
    "",
    "| Harness | Stack | Test | Cost | Agent Duration | Build Duration | Turns | Pass |",
    "| --- | --- | --- | --- | --- | --- | --- | --- |",
    ...rows,
  ].join("\n");
}

function renderScreenshots(screenshotCounts) {
  const rows = Object.entries(screenshotCounts)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([key, count]) => {
      const [harness, stack] = key.split("/");
      return `| ${harness} | ${stack} | ${count} |`;
    });

  return [
    "## Screenshots Captured",
    "",
    "| Harness | Stack | Count |",
    "| --- | --- | --- |",
    ...rows,
  ].join("\n");
}

// ---------------------------------------------------------------------------
// Short summary (terminal-friendly plain text)
// ---------------------------------------------------------------------------

function writeShortSummary(manifest, reason, records, screenshotCounts, dir) {
  const runDirName = path.basename(dir);
  const startedAt = manifest.started_at || manifest.startedAt || "—";
  const rawSha = manifest.codegen_sha || manifest.sha || "—";
  const shortSha = rawSha !== "—" ? rawSha.slice(0, 7) : "—";

  // ── helpers ──────────────────────────────────────────────────────────────

  function pad(s, w) {
    s = String(s);
    return s + " ".repeat(Math.max(0, w - s.length));
  }
  function lpad(s, w) {
    s = String(s);
    return " ".repeat(Math.max(0, w - s.length)) + s;
  }
  function fmtUSDShort(n) {
    if (n == null) return "—";
    return "$" + n.toFixed(2);
  }
  function fmtAvgUSD(n) {
    if (n == null) return "—";
    return "$" + n.toFixed(3);
  }
  function fmtIntShort(n) {
    if (n == null) return "—";
    return n.toLocaleString("en-US");
  }
  function fmtSecs(ms) {
    if (ms == null) return "—";
    return (ms / 1000).toFixed(1) + "s";
  }

  // ── pass rate ────────────────────────────────────────────────────────────

  const byHarness = {};
  for (const r of records) {
    if (!byHarness[r.harness]) byHarness[r.harness] = { passed: 0, total: 0 };
    byHarness[r.harness].total++;
    if (r.pass) byHarness[r.harness].passed++;
  }
  const claudePass = byHarness["claude"] || { passed: 0, total: 0 };
  const piPass = byHarness["pi"] || { passed: 0, total: 0 };

  function passStr(h) {
    const pct2 = h.total ? ((100 * h.passed) / h.total).toFixed(0) : "0";
    return `${h.passed}/${h.total} (${pct2}%)`;
  }

  // ── cost ─────────────────────────────────────────────────────────────────

  function harnessRecs(h) {
    return records.filter((r) => r.harness === h);
  }
  function stackRecs(h, s) {
    return records.filter((r) => r.harness === h && r.stack === s);
  }

  const claudeRecs = harnessRecs("claude");
  const piRecs = harnessRecs("pi");

  const claudeCostTotal = sumKey(claudeRecs, "cost_usd").total;
  const piCostTotal = sumKey(piRecs, "cost_usd").total;
  const claudeCostAvg = avgKey(claudeRecs, "cost_usd");
  const piCostAvg = avgKey(piRecs, "cost_usd");

  // ── tokens ───────────────────────────────────────────────────────────────

  function totalInput(recs) {
    return (
      sumKey(recs, "input_tokens").total +
      sumKey(recs, "cache_read_tokens").total +
      sumKey(recs, "cache_creation_tokens").total
    );
  }

  const claudeInput = totalInput(claudeRecs);
  const piInput = totalInput(piRecs);
  const claudeOutput = sumKey(claudeRecs, "output_tokens").total;
  const piOutput = sumKey(piRecs, "output_tokens").total;
  const claudeTokenTotal = claudeInput + claudeOutput;
  const piTokenTotal = piInput + piOutput;

  // ── assemble lines ───────────────────────────────────────────────────────

  const lines = [];

  lines.push(`Benchmark Results - ${runDirName}`);
  lines.push(`${startedAt}  SHA: ${shortSha}  Reason: ${reason || "-"}`);
  lines.push("");

  // Claude vs Pi comparison table
  const claudeShots = Object.entries(screenshotCounts)
    .filter(([k]) => k.startsWith("claude/"))
    .reduce((a, [, c]) => a + c, 0);
  const piShots = Object.entries(screenshotCounts)
    .filter(([k]) => k.startsWith("pi/"))
    .reduce((a, [, c]) => a + c, 0);

  function avgSecs(recs, key) {
    return fmtSecs(avgKey(recs, key));
  }
  function avgTurnsStr(recs) {
    const a = avgKey(recs, "num_turns");
    return a == null ? "-" : a.toFixed(1);
  }

  const metricRows = [
    ["Pass rate", passStr(claudePass), passStr(piPass)],
    ["Avg cost/test", fmtAvgUSD(claudeCostAvg), fmtAvgUSD(piCostAvg)],
    [
      "Avg build duration",
      avgSecs(claudeRecs, "build_duration_ms"),
      avgSecs(piRecs, "build_duration_ms"),
    ],
    [
      "Avg agent duration",
      avgSecs(claudeRecs, "duration_ms"),
      avgSecs(piRecs, "duration_ms"),
    ],
    ["Avg turns", avgTurnsStr(claudeRecs), avgTurnsStr(piRecs)],
    ["Total tokens", fmtIntShort(claudeTokenTotal), fmtIntShort(piTokenTotal)],
    ["Screenshots captured", String(claudeShots), String(piShots)],
  ];

  const W_METRIC = 22;
  const W_COL = 14;
  lines.push(
    pad("Metric", W_METRIC) + lpad("Claude", W_COL) + lpad("Pi", W_COL),
  );
  lines.push("-".repeat(W_METRIC + W_COL * 2));
  for (const [label, c, p] of metricRows) {
    lines.push(pad(label, W_METRIC) + lpad(c, W_COL) + lpad(p, W_COL));
  }
  lines.push("");

  const shortPath = path.join(dir, "summary-short.txt");
  fs.writeFileSync(shortPath, lines.join("\n"));
  return shortPath;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

const { manifest, reason } = loadManifest();
const { records, screenshotCounts } = collectRecords();

let markdown;
if (records.length === 0) {
  markdown = [
    renderMetadata(manifest, reason),
    "",
    "_No test records found._",
  ].join("\n");
} else {
  markdown = [
    renderMetadata(manifest, reason),
    "",
    renderPassRate(records),
    "",
    renderAverages(records),
    "",
    renderCostTable(records),
    "",
    renderTokensTable(records),
    "",
    renderDurationTurns(records),
    "",
    renderPerTestTable(records),
    "",
    renderScreenshots(screenshotCounts),
    "",
  ].join("\n");
}

const summaryPath = path.join(runDir, "summary.md");
fs.writeFileSync(summaryPath, markdown);
console.log(summaryPath);

writeShortSummary(manifest, reason, records, screenshotCounts, runDir);
