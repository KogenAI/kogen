/**
 * pitch-format-validator.ts — Pi enforcement: warn on malformed pitch files for
 * shape, refactor, and ops sessions.
 *
 * Mirrors: harnesses/claude/hooks/pitch-format-validator.sh
 * Event: session_shutdown (Stop equivalent)
 * OBSERVE-ONLY — Pi session_shutdown cannot block; warns to stderr.
 *
 * Gate (role): only enforces when PI_ROLE or CLAUDE_ROLE ∈ {shape, refactor, ops}.
 *
 * Validation rules (anchors only — never prose content):
 *   (a) > Status: line present → value MUST be SKELETON, SHAPING, or SHAPED
 *   (b) ## Questions heading present → MUST have ≥1 ### Q<n>: heading AND each
 *       Q heading must be followed by ≥2 "- **<letter>)**" option bullets before
 *       the next ### or ## heading
 *   (c) BOTH ## Questions AND ## Answers present → every "### Q<n>: " binding
 *       line under ## Answers MUST have a matching Q<n> in ## Questions.
 *
 * Skip when:
 *   - role is not shape, refactor, or ops
 *   - No pitch file found via disk-scan
 *   - Pitch file is unreadable
 *   - No ## Questions heading in pitch (optional block)
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { debugLog } from "../lib/hook-helpers";
import * as fs from "node:fs";
import * as path from "node:path";

export const HANDLER_META = {
  name: "pitch-format-validator",
  event: "session_shutdown",
  matcher: "*",
} as const;

/** Find the most recently modified pitch in codegen/pitches/. */
function getActivePitch(projectDir: string): string | null {
  const pitchesDir = path.join(projectDir, "codegen", "pitches");
  if (!fs.existsSync(pitchesDir)) return null;

  const allPitches: { fullPath: string; mtime: number }[] = [];
  for (const sub of ["ready", "shipped", "draft"]) {
    const subDir = path.join(pitchesDir, sub);
    if (!fs.existsSync(subDir)) continue;
    for (const f of fs.readdirSync(subDir)) {
      if (!f.endsWith(".md")) continue;
      const fullPath = path.join(subDir, f);
      allPitches.push({ fullPath, mtime: fs.statSync(fullPath).mtimeMs });
    }
  }

  if (allPitches.length === 0) return null;
  allPitches.sort((a, b) => b.mtime - a.mtime);
  return allPitches[0].fullPath;
}

/** Extract section body from heading to next same-level heading or EOF. */
function extractSection(content: string, heading: string): string {
  const lines = content.split("\n");
  const result: string[] = [];
  let inSection = false;
  const headingLevel = heading.match(/^(#{2,3})\s/)?.[1]?.length ?? 2;
  const sectionBoundary = new RegExp(`^#{1,${headingLevel}} `);

  for (const line of lines) {
    if (line.startsWith(heading)) {
      inSection = true;
      continue;
    }
    if (inSection && sectionBoundary.test(line) && !line.startsWith(heading)) {
      break;
    }
    if (inSection) {
      result.push(line);
    }
  }
  return result.join("\n");
}

export function register(pi: ExtensionAPI): void {
  pi.on("session_shutdown", async () => {
    const projectDir = process.env["CWD"] ?? process.cwd();
    const piRole = process.env["PI_ROLE"] ?? "";
    const claudeRole = process.env["CLAUDE_ROLE"] ?? "";
    const role = piRole || claudeRole;

    debugLog("pitch-format-validator", `role=${role}`);

    // Only enforce for shape / refactor / ops.
    if (role !== "shape" && role !== "refactor" && role !== "ops") {
      debugLog(
        "pitch-format-validator",
        `skip: role=${role} not shape/refactor/ops`,
      );
      return;
    }

    // Disk-scan for active pitch.
    const pitchPath = getActivePitch(projectDir);
    if (!pitchPath) {
      debugLog("pitch-format-validator", "skip: no pitch found");
      return;
    }

    debugLog("pitch-format-validator", `resolved pitch=${pitchPath}`);

    let pitchContent: string;
    try {
      pitchContent = fs.readFileSync(pitchPath, "utf8");
    } catch {
      debugLog(
        "pitch-format-validator",
        `skip: pitch not readable: ${pitchPath}`,
      );
      return;
    }

    // ── Validation (a): > Status: value ────────────────────────────────────
    const statusMatch = pitchContent.match(/^> Status:\s*(.+)$/m);
    if (statusMatch) {
      const statusValue = statusMatch[1].trim();
      if (
        statusValue !== "SKELETON" &&
        statusValue !== "SHAPING" &&
        statusValue !== "SHAPED"
      ) {
        process.stderr.write(
          `[pi-enforcement:pitch-format-validator] WARNING: invalid \`> Status:\` value "${statusValue}" in ${pitchPath}. Allowed values: SKELETON, SHAPING, SHAPED. Re-emit the \`> Status:\` line with one of those values.\n`,
        );
      }
    }

    // ── Validation (b) + (c): ## Questions / ## Answers blocks ─────────────
    const hasQuestions = /^## Questions/m.test(pitchContent);
    const hasAnswers = /^## Answers/m.test(pitchContent);

    // No ## Questions block → skip Q/A validation.
    if (!hasQuestions) {
      debugLog("pitch-format-validator", "allow: no ## Questions block");
      return;
    }

    const questionsSection = extractSection(pitchContent, "## Questions");

    // (b): ## Questions must have ≥1 ### Q<n>: heading.
    const qHeadings = questionsSection.match(/^### Q\d+:/gm) ?? [];
    if (qHeadings.length === 0) {
      process.stderr.write(
        `[pi-enforcement:pitch-format-validator] WARNING: \`## Questions\` block in ${pitchPath} has no \`### Q<n>:\` headings. Each question must use \`### Q1:\`, \`### Q2:\`, etc. Re-emit the ## Questions/## Answers block following the pitch-format grammar.\n`,
      );
      return;
    }

    // (b): Each ### Q<n>: must have ≥2 "- **<letter>)**" option bullets.
    const qLines = questionsSection.split("\n");
    let inQ = false;
    let currentQ = "";
    let bulletCount = 0;

    for (const line of qLines) {
      if (/^### Q\d+:/.test(line)) {
        if (inQ && bulletCount < 2) {
          process.stderr.write(
            `[pi-enforcement:pitch-format-validator] WARNING: question \`${currentQ}\` in \`## Questions\` of ${pitchPath} has fewer than 2 option bullets (\`- **<letter>)**\`). Each question must have ≥2 concrete options. Re-emit the ## Questions/## Answers block following the pitch-format grammar.\n`,
          );
        }
        inQ = true;
        currentQ = line.replace(/^### /, "");
        bulletCount = 0;
      } else if (/^- \*\*[a-zA-Z]\)\*\*/.test(line) && inQ) {
        bulletCount++;
      }
    }
    // Check last Q.
    if (inQ && bulletCount < 2) {
      process.stderr.write(
        `[pi-enforcement:pitch-format-validator] WARNING: question \`${currentQ}\` in \`## Questions\` of ${pitchPath} has fewer than 2 option bullets (\`- **<letter>)**\`). Each question must have ≥2 concrete options. Re-emit the ## Questions/## Answers block following the pitch-format grammar.\n`,
      );
    }

    // ── (c): ## Answers Q-bindings must match Questions ─────────────────────
    if (hasAnswers) {
      const answersSection = extractSection(pitchContent, "## Answers");
      const qNums = new Set(
        qHeadings.map((h) => h.match(/Q(\d+)/)?.[1]).filter(Boolean),
      );
      const answerRefs = (answersSection.match(/^### Q(\d+)/gm) ?? []).map(
        (r) => r.match(/Q(\d+)/)?.[1],
      );

      for (const ref of answerRefs) {
        if (ref && !qNums.has(ref)) {
          process.stderr.write(
            `[pi-enforcement:pitch-format-validator] WARNING: \`## Answers\` in ${pitchPath} contains binding for \`Q${ref}\` but \`## Questions\` has no matching \`### Q${ref}:\` heading. Remove the stray answer or add the corresponding question. Re-emit the ## Questions/## Answers block following the pitch-format grammar.\n`,
          );
        }
      }
    }

    debugLog("pitch-format-validator", `allow: pitch=${pitchPath}`);
  });
}
