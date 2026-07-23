#!/usr/bin/env node
// pitch-postflight.cjs — deterministic postflight validator for a Pi
// investigative session (shape/ops/experiment) that may have changed
// pitch files.
//
// Usage:
//   node pitch-postflight.cjs --mode <shape|ops|experiment> --root <repo-root> --snapshot <json-file>
//
// The snapshot JSON is { "<repo-relative-pitch-path>": "<sha256-hex-or-empty>" }
// captured BEFORE the Pi session started (empty string = file did not exist
// pre-session). Postflight re-hashes the CURRENT state of every path in
// codegen/pitches/{draft,ready,shipped}/*.md, diffs against the snapshot to
// find changed/new pitches, and validates each one against the pitch-format
// grammar (same anchors as pitch-format-validator.ts/.sh):
//   (a) status: enum SKELETON|SHAPING|SHAPED
//   (b) ## Questions structure (>=1 ### Q<n>:, each with >=2 option bullets)
//   (c) ## Answers Q-bindings match ## Questions
//   (d) waives: ids resolve to a waivable: true registry entry
//   (e) SHAPED-only: parseable non-empty scope:, persisted summary:, zero
//       open ## Questions (no ## Questions block, or the block being fully
//       superseded by ## Answers is NOT sufficient — SHAPED requires the
//       block absent or empty of unresolved questions)
//
// A pitch unchanged from the pre-session snapshot is a no-op — validation
// runs ONLY on changed/new pitches. Invalid/unreadable pitch → exit 1,
// naming the file and the violated rule. Unchanged session (nothing in
// codegen/pitches/ differs from the snapshot) → exit 0, prints a no-op note.
//
// This module is the shared grammar authority for BOTH the interactive
// wrapper (pitch-postflight.sh) and any direct CLI/test invocation. It
// performs NO process supervision, NO signal handling — that is the shell
// wrapper's job.

"use strict";

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

function parseArgs(argv) {
  const out = { mode: "", root: "", snapshot: "" };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--mode") out.mode = argv[++i] ?? "";
    else if (a === "--root") out.root = argv[++i] ?? "";
    else if (a === "--snapshot") out.snapshot = argv[++i] ?? "";
  }
  return out;
}

function sha256(text) {
  return crypto.createHash("sha256").update(text, "utf8").digest("hex");
}

/** Enumerate every codegen/pitches/{draft,ready,shipped}/*.md relative to root. */
function listPitchPaths(root) {
  const pitchesDir = path.join(root, "codegen", "pitches");
  const out = [];
  for (const sub of ["draft", "ready", "shipped"]) {
    const subDir = path.join(pitchesDir, sub);
    if (!fs.existsSync(subDir)) continue;
    for (const f of fs.readdirSync(subDir)) {
      if (!f.endsWith(".md")) continue;
      out.push(path.join("codegen", "pitches", sub, f));
    }
  }
  return out;
}

function currentHash(root, relPath) {
  const full = path.join(root, relPath);
  if (!fs.existsSync(full)) return "";
  try {
    return sha256(fs.readFileSync(full, "utf8"));
  } catch {
    return "";
  }
}

/** Extract the raw text of a leading YAML frontmatter block, or null. */
function frontmatterBlock(content) {
  if (!content.startsWith("---\n") && content !== "---") return null;
  const rest = content.slice(content.indexOf("\n") + 1);
  const closeIdx = rest.indexOf("\n---");
  if (closeIdx === -1) return null;
  return rest.slice(0, closeIdx);
}

function extractSection(content, heading) {
  const lines = content.split("\n");
  const result = [];
  let inSection = false;
  const headingLevel = (heading.match(/^(#{2,3})\s/) || [])[1]?.length ?? 2;
  const sectionBoundary = new RegExp(`^#{1,${headingLevel}} `);

  for (const line of lines) {
    if (line.startsWith(heading)) {
      inSection = true;
      continue;
    }
    if (inSection && sectionBoundary.test(line) && !line.startsWith(heading)) {
      break;
    }
    if (inSection) result.push(line);
  }
  return result.join("\n");
}

function registryAllowsWaiver(root, hookId) {
  const reg = path.join(root, "shared", "enforcement", "registry.yaml");
  if (!fs.existsSync(reg)) return false;
  let text;
  try {
    text = fs.readFileSync(reg, "utf8");
  } catch {
    return false;
  }
  const lines = text.split("\n");
  let inBlock = false;
  for (const line of lines) {
    const trimmed = line.trim();
    if (/^id:\s+\S+/.test(trimmed)) {
      const [, id] = trimmed.split(/\s+/, 2);
      inBlock = id === hookId;
      continue;
    }
    if (inBlock && trimmed === "") {
      inBlock = false;
      continue;
    }
    if (inBlock && /^waivable:\s*true\s*$/.test(trimmed)) return true;
  }
  return false;
}

/**
 * Validate one pitch's content. Returns { ok: true } or
 * { ok: false, reason: <string> } — reason names the file and violated rule.
 */
function validatePitch(root, relPath, content) {
  const fmBlock = frontmatterBlock(content);

  // (a) status enum.
  let statusValue = null;
  let statusSource = "";
  if (fmBlock !== null) {
    const m = fmBlock.match(/^status:\s*(.+)$/m);
    if (m) {
      statusValue = m[1].trim();
      statusSource = "frontmatter status:";
    }
  }
  if (statusValue === null) {
    const m = content.match(/^> Status:\s*(.+)$/m);
    if (m) {
      statusValue = m[1].trim();
      statusSource = "legacy `> Status:`";
    }
  }
  if (
    statusValue !== null &&
    !["SKELETON", "SHAPING", "SHAPED"].includes(statusValue)
  ) {
    return {
      ok: false,
      reason: `${relPath}: invalid ${statusSource} value "${statusValue}". Allowed: SKELETON, SHAPING, SHAPED.`,
    };
  }

  // (d) waives: ids must be waivable: true registry entries.
  if (fmBlock !== null) {
    const waivesMatch = fmBlock.match(/^waives:\s*(.+)$/m);
    if (waivesMatch) {
      const ids = waivesMatch[1]
        .replace(/[[\]]/g, "")
        .split(",")
        .map((s) => s.trim())
        .filter((s) => s.length > 0);
      for (const wid of ids) {
        if (!registryAllowsWaiver(root, wid)) {
          return {
            ok: false,
            reason: `${relPath}: waives: names "${wid}", which is not a registry entry with waivable: true.`,
          };
        }
      }
    }
  }

  const hasQuestions = /^## Questions/m.test(content);
  const hasAnswers = /^## Answers/m.test(content);

  let qHeadings = [];
  if (hasQuestions) {
    const questionsSection = extractSection(content, "## Questions");
    qHeadings = questionsSection.match(/^### Q\d+:/gm) ?? [];

    // (b) at least 1 Q heading.
    if (qHeadings.length === 0) {
      return {
        ok: false,
        reason: `${relPath}: \`## Questions\` block has no \`### Q<n>:\` headings.`,
      };
    }

    // (b) each Q heading needs >=2 option bullets.
    const qLines = questionsSection.split("\n");
    let inQ = false;
    let currentQ = "";
    let bulletCount = 0;
    for (const line of qLines) {
      if (/^### Q\d+:/.test(line)) {
        if (inQ && bulletCount < 2) {
          return {
            ok: false,
            reason: `${relPath}: question "${currentQ}" has fewer than 2 option bullets.`,
          };
        }
        inQ = true;
        currentQ = line.replace(/^### /, "");
        bulletCount = 0;
      } else if (/^- \*\*[a-zA-Z]\)\*\*/.test(line) && inQ) {
        bulletCount++;
      }
    }
    if (inQ && bulletCount < 2) {
      return {
        ok: false,
        reason: `${relPath}: question "${currentQ}" has fewer than 2 option bullets.`,
      };
    }

    // (c) Answers Q-bindings must match Questions.
    if (hasAnswers) {
      const answersSection = extractSection(content, "## Answers");
      const qNums = new Set(
        qHeadings.map((h) => (h.match(/Q(\d+)/) || [])[1]).filter(Boolean),
      );
      const answerRefs = (answersSection.match(/^### Q(\d+)/gm) ?? []).map(
        (r) => (r.match(/Q(\d+)/) || [])[1],
      );
      for (const ref of answerRefs) {
        if (ref && !qNums.has(ref)) {
          return {
            ok: false,
            reason: `${relPath}: \`## Answers\` binds Q${ref} but \`## Questions\` has no matching heading.`,
          };
        }
      }
    }
  }

  // (e) SHAPED-only completeness: parseable non-empty scope:, persisted
  // summary:, zero open Questions. SKELETON/SHAPING may keep open Questions
  // and omit SHAPED-only metadata.
  if (statusValue === "SHAPED") {
    if (hasQuestions) {
      return {
        ok: false,
        reason: `${relPath}: status: SHAPED but \`## Questions\` block is still present — zero open Questions required at SHAPED.`,
      };
    }
    if (fmBlock === null) {
      return {
        ok: false,
        reason: `${relPath}: status: SHAPED requires a frontmatter block with scope: and summary:.`,
      };
    }
    const scopeMatch = fmBlock.match(/^scope:\s*(.*)$/m);
    if (
      !scopeMatch ||
      scopeMatch[1].trim() === "" ||
      scopeMatch[1].trim() === "[]"
    ) {
      // scope: [] (explicitly empty) is disallowed at SHAPED — a shaped
      // pitch must name what it edits. Multiline scope: (key alone, `[`
      // on a following line) also satisfies non-empty when the block
      // contains at least one non-bracket, non-blank line after the key.
      const multilineOk =
        scopeMatch &&
        scopeMatch[1].trim() === "" &&
        /^scope:\s*$/m.test(fmBlock) &&
        /^\s*-\s*\S+/m.test(fmBlock);
      if (!multilineOk) {
        return {
          ok: false,
          reason: `${relPath}: status: SHAPED requires a parseable non-empty scope: field.`,
        };
      }
    }
    if (!/^summary:\s*>/m.test(fmBlock) && !/^summary:\s*\S+/m.test(fmBlock)) {
      return {
        ok: false,
        reason: `${relPath}: status: SHAPED requires a persisted summary: field.`,
      };
    }
  }

  return { ok: true };
}

function loadSnapshot(snapshotPath) {
  if (!snapshotPath) return {};
  if (!fs.existsSync(snapshotPath)) return {};
  try {
    return JSON.parse(fs.readFileSync(snapshotPath, "utf8"));
  } catch {
    return {};
  }
}

function run(argv) {
  const { mode, root, snapshot } = parseArgs(argv);

  if (!mode || !root) {
    process.stderr.write("pitch-postflight: --mode and --root are required\n");
    return 2;
  }
  if (!["shape", "ops", "experiment"].includes(mode)) {
    process.stderr.write(
      `pitch-postflight: unknown mode "${mode}" (expected shape|ops|experiment)\n`,
    );
    return 2;
  }

  const before = loadSnapshot(snapshot);
  const currentPaths = listPitchPaths(root);
  const allPaths = new Set([...Object.keys(before), ...currentPaths]);

  const changed = [];
  for (const relPath of allPaths) {
    const beforeHash = before[relPath] ?? "";
    const afterHash = currentHash(root, relPath);
    if (beforeHash !== afterHash) changed.push(relPath);
  }

  if (changed.length === 0) {
    process.stdout.write(
      `pitch-postflight: no-op — no pitch changed this session (mode=${mode})\n`,
    );
    return 0;
  }

  let failed = false;
  for (const relPath of changed) {
    const full = path.join(root, relPath);
    if (!fs.existsSync(full)) {
      // Deleted pitch — not a validation target.
      continue;
    }
    let content;
    try {
      content = fs.readFileSync(full, "utf8");
    } catch (e) {
      process.stderr.write(
        `pitch-postflight: FAILED — ${relPath} unreadable: ${e.message}\n`,
      );
      failed = true;
      continue;
    }
    const result = validatePitch(root, relPath, content);
    if (!result.ok) {
      process.stderr.write(`pitch-postflight: FAILED — ${result.reason}\n`);
      failed = true;
    }
  }

  if (failed) return 1;

  process.stdout.write(
    `pitch-postflight: OK — ${changed.length} changed pitch(es) validated (mode=${mode})\n`,
  );
  return 0;
}

if (require.main === module) {
  process.exit(run(process.argv.slice(2)));
}

module.exports = { run, validatePitch, listPitchPaths, sha256, loadSnapshot };
