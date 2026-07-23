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
 *   (a) YAML frontmatter `status:` key present (leading ---...--- block) OR
 *       legacy `> Status:` line present → value MUST be SKELETON, SHAPING,
 *       or SHAPED. Frontmatter is checked first; falls back to the
 *       blockquote form for pre-existing pitches with no frontmatter
 *       (dual-read).
 *   (b) ## Questions heading present → MUST have ≥1 ### Q<n>: heading AND each
 *       Q heading must be followed by ≥2 "- **<letter>)**" option bullets before
 *       the next ### or ## heading
 *   (c) BOTH ## Questions AND ## Answers present → every "### Q<n>: " binding
 *       line under ## Answers MUST have a matching Q<n> in ## Questions.
 *   (d) YAML frontmatter `waives:` flow-list present → every id MUST resolve
 *       to a shared/enforcement/registry.yaml entry AND that entry MUST
 *       carry `waivable: true`.
 *
 * Skip when:
 *   - role is not shape, refactor, or ops
 *   - No pitch file found via disk-scan
 *   - Pitch file is unreadable
 *   - No ## Questions heading in pitch (optional block)
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { debugLog, repoRoot } from "../lib/hook-helpers";
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

/**
 * Extract the raw text of a leading YAML frontmatter block (between the
 * opening and closing `---` delimiters), or null if `content` does not
 * open with one. The opening delimiter MUST be the very first line.
 */
function frontmatterBlock(content: string): string | null {
  if (!content.startsWith("---\n") && content !== "---") return null;
  const rest = content.slice(content.indexOf("\n") + 1);
  const closeIdx = rest.indexOf("\n---");
  if (closeIdx === -1) return null;
  return rest.slice(0, closeIdx);
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

/** True iff shared/enforcement/registry.yaml marks hookId waivable: true. */
function registryAllowsWaiver(projectDir: string, hookId: string): boolean {
  const root = process.env["CODEGEN_DIR"] || repoRoot(projectDir);
  const reg = path.join(root, "shared/enforcement/registry.yaml");
  if (!fs.existsSync(reg)) return false;
  let text: string;
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
    if (inBlock && /^waivable:\s*true\s*$/.test(trimmed)) {
      return true;
    }
  }
  return false;
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

    // ── Validation (a): status value (frontmatter status: first, dual-read
    // with legacy > Status: blockquote) ─────────────────────────────────────
    let statusValue: string | null = null;
    let statusSource = "";

    const fmBlock = frontmatterBlock(pitchContent);
    if (fmBlock !== null) {
      const fmStatusMatch = fmBlock.match(/^status:\s*(.+)$/m);
      if (fmStatusMatch) {
        statusValue = fmStatusMatch[1].trim();
        statusSource = "frontmatter status:";
      }
    }

    if (statusValue === null) {
      const statusMatch = pitchContent.match(/^> Status:\s*(.+)$/m);
      if (statusMatch) {
        statusValue = statusMatch[1].trim();
        statusSource = "legacy `> Status:`";
      }
    }

    if (statusValue !== null) {
      if (
        statusValue !== "SKELETON" &&
        statusValue !== "SHAPING" &&
        statusValue !== "SHAPED"
      ) {
        process.stderr.write(
          `[pi-enforcement:pitch-format-validator] WARNING: invalid ${statusSource} value "${statusValue}" in ${pitchPath}. Allowed values: SKELETON, SHAPING, SHAPED. Re-emit the status field with one of those values.\n`,
        );
      }
    }

    // ── Validation (d): waives: frontmatter — every id must be a registry
    // entry with waivable: true. Runs BEFORE the (b)/(c) Questions
    // early-return, so a SHAPED pitch with no ## Questions block still gets
    // this check. ────────────────────────────────────────────────────────
    if (fmBlock !== null) {
      const waivesMatch = fmBlock.match(/^waives:\s*(.+)$/m);
      if (waivesMatch) {
        const ids = waivesMatch[1]
          .replace(/[[\]]/g, "")
          .split(",")
          .map((s) => s.trim())
          .filter((s) => s.length > 0);
        for (const wid of ids) {
          if (!registryAllowsWaiver(projectDir, wid)) {
            process.stderr.write(
              `[pi-enforcement:pitch-format-validator] WARNING: \`waives:\` in ${pitchPath} names \`${wid}\`, which is not a registry entry with \`waivable: true\`. Only guards that opt in via \`waivable: true\` in shared/enforcement/registry.yaml may be waived. Remove the entry or fix the id.\n`,
            );
          }
        }
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
