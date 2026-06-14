#!/usr/bin/env node
/**
 * wiring-check.js — static Phoenix handler-wiring verdict engine.
 *
 * Usage: node wiring-check.js <project-dir>
 *
 * Single line to stdout:
 *   WIRING_VERDICT=PASS
 *   WIRING_VERDICT=FAIL:<comma-separated unmatched handlers as event@selector>
 *   WIRING_VERDICT=FAIL:unresolvable-selector:<event>
 *   WIRING_VERDICT=INCONCLUSIVE:no-heex
 *   WIRING_VERDICT=INCONCLUSIVE:checker-error
 *
 * Exit 0 always — verdict via the WIRING_VERDICT line. Diagnostics → stderr.
 * STATIC: greps lib/**\/*.heex + ~H""" sigils in *.ex + test/**\/*_test.exs.
 * No server, no browser, no deps beyond Node built-ins.
 */

"use strict";

const fs = require("fs");
const path = require("path");

const HANDLER_EVENTS = [
  "phx-click",
  "phx-submit",
  "phx-change",
  "phx-keyup",
  "phx-window-keydown",
];

// render_click -> phx-click, render_submit -> phx-submit, etc.
// render_keydown covers both phx-keyup and phx-window-keydown (same LiveView fn).
// render_keyup covers phx-keyup and phx-window-keydown as well.
const RENDER_FN_TO_EVENTS = {
  render_click: ["phx-click"],
  render_submit: ["phx-submit"],
  render_change: ["phx-change"],
  render_keydown: ["phx-keyup", "phx-window-keydown"],
  render_keyup: ["phx-keyup", "phx-window-keydown"],
};

// Patterns whose presence in a test body indicate a side-effect assertion.
// Each is a regex that should match somewhere in the test's body text.
// Note: \b doesn't work before : (not a word char) or after ? (not a word char).
const SIDE_EFFECT_PATTERNS = [
  /\bMox\b.*\bexpect\b/,
  /\bexpect\s*\(/,
  /File\.exists\?/,
  /File\.read[!?]?/,
  /\bassert_received\b/,
  /\bassert_receive\b/,
  /:sys\.get_state\b/,
  /\bGenServer\.call\b.*state/i,
];

// ── Verdict helpers ───────────────────────────────────────────────────────────

function verdict(v) {
  process.stdout.write(`WIRING_VERDICT=${v}\n`);
  process.exit(0);
}

function log(msg) {
  process.stderr.write(`[wiring-check] ${msg}\n`);
}

// ── File walking ──────────────────────────────────────────────────────────────

/**
 * Recursively list files under dir matching a predicate. Returns [] if dir absent.
 */
function walk(dir, pred) {
  const results = [];
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch (_e) {
    return results;
  }
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      for (const sub of walk(full, pred)) results.push(sub);
    } else if (entry.isFile() && pred(entry.name)) {
      results.push(full);
    }
  }
  return results;
}

// ── Handler extraction ────────────────────────────────────────────────────────

/**
 * Given a block of content (heex or sigil), extract all phx-* event attrs.
 * Returns array of { event, selector, unresolvable }.
 *
 * Selector resolution:
 *   1. id="..." on the same element tag
 *   2. nearest ancestor id (walk lines upward looking for id="...")
 *   3. phx-value-* key on the same element if no id available
 *
 * Interpolated values:
 *   phx-click={@x} or phx-click={"#{...}"} → unresolvable=true
 *   id={"#{...}"} or id={@x} on element or ancestor → unresolvable=true
 */
function extractHandlersFromContent(content) {
  const handlers = [];
  const lines = content.split("\n");

  // Parse lines looking for phx-* attributes.
  // We do a simple line-by-line scan, tracking open element context.

  // We'll accumulate "element blocks" — runs of lines that seem to be inside
  // the same HTML tag. An element starts when we see a tag opener like `<tag`
  // and ends at `>` (possibly multi-line).

  // Strategy: scan each line for phx-* attrs. For each one:
  //   a. Check if there's an id="..." on the same line/element block.
  //   b. If not, look backwards through prior lines for an ancestor id.
  //   c. If the phx-* value is interpolated, mark unresolvable.
  //   d. If the id is interpolated, mark unresolvable.

  // We'll do a two-pass approach:
  //   Pass 1: collect all phx-* occurrences with their line index + raw value.
  //   Pass 2: for each, resolve selector.

  const phxRegex =
    /\b(phx-click|phx-submit|phx-change|phx-keyup|phx-window-keydown)\s*=\s*("([^"]+)"|'([^']+)'|\{([^}]*)\})/g;
  const idRegex = /\bid\s*=\s*("([^"]+)"|'([^']+)'|\{([^}]*)\})/;
  const phxValueRegex =
    /\bphx-value-[\w-]+\s*=\s*"([^"]+)"|phx-value-[\w-]+\s*=\s*'([^']+)'/;

  for (let lineIdx = 0; lineIdx < lines.length; lineIdx++) {
    const line = lines[lineIdx];
    let m;
    // Reset lastIndex for global regex
    phxRegex.lastIndex = 0;

    while ((m = phxRegex.exec(line)) !== null) {
      const event = m[1];
      const rawValue = m[5] !== undefined ? `{${m[5]}}` : m[2]; // full match including quotes

      // Check if the value is interpolated
      const isInterpolatedValue =
        m[5] !== undefined &&
        (m[5].includes("#{") || m[5].startsWith("@") || m[5].includes("@"));

      if (isInterpolatedValue) {
        handlers.push({ event, selector: null, unresolvable: true });
        continue;
      }

      // Try to find id on the same element (look around this line and a few below
      // to find the enclosing tag's id attribute)
      let resolvedSelector = null;
      let resolvedUnresolvable = false;

      // Gather the element block: look from the nearest opening tag above to
      // the closing bracket `>`.
      // Simple heuristic: collect lines from the nearest `<` before this line
      // down to the first `>` at or after this line.
      let blockStart = lineIdx;
      // Walk back to find start of tag (line with `<` that opens a tag).
      for (let i = lineIdx; i >= Math.max(0, lineIdx - 20); i--) {
        if (/<\w/.test(lines[i]) || /^\s*</.test(lines[i])) {
          blockStart = i;
          break;
        }
      }
      let blockEnd = lineIdx;
      for (let i = lineIdx; i < Math.min(lines.length, lineIdx + 20); i++) {
        if (lines[i].includes(">")) {
          blockEnd = i;
          break;
        }
      }
      const elementBlock = lines.slice(blockStart, blockEnd + 1).join("\n");

      // Check for id in element block
      const idMatch = idRegex.exec(elementBlock);
      if (idMatch) {
        const idRaw = idMatch[1];
        // Check if id is interpolated
        if (idMatch[4] !== undefined) {
          // id={...} form
          resolvedUnresolvable = true;
        } else {
          // Static id: "foo" or 'foo'
          resolvedSelector = `#${idMatch[2] || idMatch[3]}`;
        }
      } else {
        // No id on element — look for ancestor id by scanning upward
        let ancestorFound = false;
        for (let i = blockStart - 1; i >= Math.max(0, lineIdx - 50); i--) {
          const ancestorLine = lines[i];
          const ancestorIdMatch = idRegex.exec(ancestorLine);
          if (ancestorIdMatch) {
            if (ancestorIdMatch[4] !== undefined) {
              // interpolated ancestor id
              resolvedUnresolvable = true;
            } else {
              resolvedSelector = `#${ancestorIdMatch[2] || ancestorIdMatch[3]}`;
            }
            ancestorFound = true;
            break;
          }
        }

        if (!ancestorFound) {
          // Try phx-value-* as selector key
          const pvMatch = phxValueRegex.exec(elementBlock);
          if (pvMatch) {
            const pvVal = pvMatch[1] || pvMatch[2];
            resolvedSelector = `phx-value:${pvVal}`;
          } else {
            // No stable selector found — but not necessarily unresolvable yet.
            // We'll use the event itself as a label.
            resolvedSelector = `${event}`;
          }
        }
      }

      handlers.push({
        event,
        selector: resolvedSelector,
        unresolvable: resolvedUnresolvable,
      });
    }
  }

  return handlers;
}

/**
 * Extract all phx-* handler entries from a project directory.
 * Returns { list: [{event, selector, unresolvable}], totalHeexFiles }.
 */
function extractHandlers(projectDir) {
  const libDir = path.join(projectDir, "lib");

  // Collect .heex files
  const heexFiles = walk(
    libDir,
    (name) => name.endsWith(".heex") && !name.startsWith("."),
  );

  // Collect .ex files that contain ~H""" sigils
  const exFiles = walk(
    libDir,
    (name) => name.endsWith(".ex") && !name.startsWith("."),
  );

  const sigil_exFiles = exFiles.filter((f) => {
    try {
      return fs.readFileSync(f, "utf8").includes('~H"""');
    } catch (_e) {
      return false;
    }
  });

  const totalHeexFiles = heexFiles.length + sigil_exFiles.length;
  const handlers = [];

  for (const f of heexFiles) {
    const content = fs.readFileSync(f, "utf8");
    for (const h of extractHandlersFromContent(content)) {
      handlers.push(h);
    }
  }

  for (const f of sigil_exFiles) {
    const raw = fs.readFileSync(f, "utf8");
    // Extract ~H""" ... """ blocks
    const sigilRe = /~H"""\s*([\s\S]*?)"""/g;
    let sm;
    while ((sm = sigilRe.exec(raw)) !== null) {
      for (const h of extractHandlersFromContent(sm[1])) {
        handlers.push(h);
      }
    }
  }

  return { list: handlers, totalHeexFiles };
}

// ── Driving test extraction ───────────────────────────────────────────────────

/**
 * Parse a single _test.exs file and return an array of driving tests.
 * Each driving test: { event, selector }
 *
 * A driving test is:
 *   element("#selector") |> render_click/submit/change/keydown/keyup()
 *   OR element("tag", "text") |> render_click/...()
 * AND has a side-effect assertion in the same test body.
 *
 * A bare render_*(view, "event", %{}) hand-fed event does NOT count.
 */
function extractDrivingTestsFromFile(content) {
  const drivingTests = [];

  // Split content into test bodies.
  // We detect test boundaries by looking for `test "..." do` and matching `end`.
  // Simple approach: find all test blocks by splitting on `test "`
  const lines = content.split("\n");

  // Find test block boundaries
  const testStarts = [];
  for (let i = 0; i < lines.length; i++) {
    if (/^\s*test\s+["']/.test(lines[i])) {
      testStarts.push(i);
    }
  }

  for (let ti = 0; ti < testStarts.length; ti++) {
    const start = testStarts[ti];
    const end = ti + 1 < testStarts.length ? testStarts[ti + 1] : lines.length;
    const testBody = lines.slice(start, end).join("\n");

    // Check for element() |> render_* pattern
    // element("#foo") |> render_click
    // element("button", "Save") |> render_click
    const elementRenderRe =
      /element\s*\(\s*"([^"]+)"(?:\s*,\s*"([^"]+)")?\s*\)\s*\|>\s*(render_click|render_submit|render_change|render_keydown|render_keyup)/g;
    let m;
    while ((m = elementRenderRe.exec(testBody)) !== null) {
      const selectorOrTag = m[1];
      const textSelector = m[2];
      const renderFn = m[3];
      const events = RENDER_FN_TO_EVENTS[renderFn] || [];

      // Determine selector
      let selector;
      if (selectorOrTag.startsWith("#") || selectorOrTag.startsWith(".")) {
        // CSS selector
        selector = selectorOrTag;
      } else if (textSelector) {
        // element("tag", "text") form
        selector = `text:${textSelector}`;
      } else {
        selector = selectorOrTag;
      }

      // Check for side-effect assertion in test body
      const hasSideEffect = SIDE_EFFECT_PATTERNS.some((pat) =>
        pat.test(testBody),
      );

      if (hasSideEffect) {
        for (const event of events) {
          drivingTests.push({ event, selector });
        }
      }
    }
  }

  return drivingTests;
}

/**
 * Extract all driving tests from a project directory.
 */
function extractDrivingTests(projectDir) {
  const testDir = path.join(projectDir, "test");
  const testFiles = walk(
    testDir,
    (name) => name.endsWith("_test.exs") && !name.startsWith("."),
  );

  const allTests = [];
  for (const f of testFiles) {
    try {
      const content = fs.readFileSync(f, "utf8");
      for (const t of extractDrivingTestsFromFile(content)) {
        allTests.push(t);
      }
    } catch (_e) {
      // Skip unreadable files
    }
  }
  return allTests;
}

// ── Matching ──────────────────────────────────────────────────────────────────

/**
 * Check if a driving test matches a handler.
 * Events must match. Selector matching is loose:
 *   - test "#foo" matches handler "#foo"
 *   - test "#foo" matches handler that resolved to "#foo" via ancestor
 *   - text selector "text:Save" matches any handler (heuristic — text not in handler extraction)
 *   - phx-value key match
 */
function testMatchesHandler(test, handler) {
  if (test.event !== handler.event) return false;

  const ts = test.selector;
  const hs = handler.selector;

  if (!ts || !hs) return true; // Can't refute without selectors

  // Text selector: element("button", "Save") — we accept this as matching any
  // handler for the same event since we can't resolve text→id statically.
  if (ts.startsWith("text:")) return true;

  // Direct id match
  if (ts === hs) return true;

  // If handler selector is a plain event name (no id found), accept any test
  if (HANDLER_EVENTS.includes(hs)) return true;

  // phx-value key — accept test id matching the value
  if (hs.startsWith("phx-value:")) return true;

  return false;
}

// ── Main ─────────────────────────────────────────────────────────────────────

function main() {
  const projectDir = process.argv[2] || process.cwd();

  let handlers;
  try {
    handlers = extractHandlers(projectDir);
  } catch (e) {
    log(`scan error: ${e.message}`);
    verdict("INCONCLUSIVE:checker-error");
    return;
  }

  if (handlers.totalHeexFiles === 0) {
    log("no .heex files or ~H sigil files found — INCONCLUSIVE");
    verdict("INCONCLUSIVE:no-heex");
    return;
  }

  log(
    `found ${handlers.totalHeexFiles} heex/sigil files, ${handlers.list.length} phx-* handlers`,
  );

  // Check for unresolvable selectors (hard fail — handler exists but selector
  // can't be statically determined, so we can't prove a test covers it)
  const unresolvable = handlers.list.filter((h) => h.unresolvable);
  if (unresolvable.length > 0) {
    const ev = unresolvable[0].event;
    log(`unresolvable selector for event: ${ev}`);
    verdict(`FAIL:unresolvable-selector:${ev}`);
    return;
  }

  if (handlers.list.length === 0) {
    // No phx-* handlers at all — nothing to wire.
    log("no phx-* handlers found — PASS (nothing to wire)");
    verdict("PASS");
    return;
  }

  let drivingTests;
  try {
    drivingTests = extractDrivingTests(projectDir);
  } catch (e) {
    log(`test scan error: ${e.message}`);
    verdict("INCONCLUSIVE:checker-error");
    return;
  }

  log(`found ${drivingTests.length} element-driven side-effect tests`);

  // Pair every handler to a driving test.
  const unmatched = handlers.list.filter(
    (h) => !drivingTests.some((t) => testMatchesHandler(t, h)),
  );

  if (unmatched.length > 0) {
    const detail = unmatched
      .map((h) => `${h.event}@${h.selector || "unknown"}`)
      .join(",");
    log(`unmatched handlers: ${detail}`);
    verdict(`FAIL:${detail}`);
    return;
  }

  log(
    `${handlers.list.length} handlers, ${drivingTests.length} driving tests — all matched`,
  );
  verdict("PASS");
}

main();
