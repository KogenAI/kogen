/**
 * post-developer-format.ts — Pi enforcement: auto-format changed files on
 * developer session shutdown (SubagentStop equivalent).
 *
 * Mirrors: templates/shared/hooks/post-developer-format.sh
 * Event: session_shutdown (SubagentStop equivalent)
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { parseAgentType, debugLog } from "../lib/hook-helpers";
import { execSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";

export const HANDLER_META = {
  name: "post-developer-format",
  event: "session_shutdown",
  matcher:
    "developer-phoenix-backend|developer-phoenix-frontend|developer-static",
} as const;

const DEV_AGENTS = new Set([
  "developer-phoenix-backend",
  "developer-phoenix-frontend",
  "developer-static",
]);

export function register(pi: ExtensionAPI): void {
  pi.on("session_shutdown", async () => {
    const agentType = parseAgentType();
    if (!DEV_AGENTS.has(agentType)) return;

    const projectDir = process.env["CWD"] ?? process.cwd();
    debugLog("post-developer-format", `agent=${agentType} cwd=${projectDir}`);

    try {
      process.chdir(projectDir);
    } catch {
      return;
    }

    // Collect changed files from git diff
    let changedFiles: string[] = [];
    try {
      const branchBase =
        execSync("git merge-base origin/main HEAD 2>/dev/null || echo HEAD", {
          encoding: "utf8",
        }).trim() || "HEAD";

      const diffOutput = execSync(
        `git diff --name-only --diff-filter=ACMR ${branchBase} HEAD && git diff --name-only HEAD`,
        { encoding: "utf8", cwd: projectDir },
      );
      changedFiles = diffOutput.split("\n").filter(Boolean);
    } catch {
      return;
    }

    if (changedFiles.length === 0) return;

    // mix format on Elixir files for Phoenix devs
    if (
      agentType === "developer-phoenix-backend" ||
      agentType === "developer-phoenix-frontend"
    ) {
      const exFiles = changedFiles.filter((f) => /\.(ex|exs|heex)$/.test(f));
      if (
        exFiles.length > 0 &&
        fs.existsSync(path.join(projectDir, "mix.exs"))
      ) {
        try {
          execSync(`mix format ${exFiles.join(" ")}`, {
            cwd: projectDir,
            stdio: "ignore",
          });
          debugLog(
            "post-developer-format",
            `mix format: ${exFiles.length} file(s)`,
          );
        } catch {
          // Non-fatal
        }
      }
    }

    // prettier on web/config files
    const prettierFiles = changedFiles.filter((f) =>
      /\.(js|ts|jsx|tsx|css|scss|json|md|yml|yaml|html)$/.test(f),
    );
    if (prettierFiles.length > 0) {
      try {
        execSync(
          `npx --no-install prettier --write --log-level=warn ${prettierFiles.join(" ")}`,
          { cwd: projectDir, stdio: "ignore" },
        );
        debugLog(
          "post-developer-format",
          `prettier: ${prettierFiles.length} file(s)`,
        );
      } catch {
        // Non-fatal
      }
    }

    // LLM-test signal detection
    const llmPattern =
      /context\/llm\.md|.*\.md\.j2|codegen\/rules\/|codegen\/recipes\/|context\/apps\/CLAUDE-.*\.md/;
    const llmFiles = changedFiles.filter((f) => llmPattern.test(f));

    if (llmFiles.length > 0) {
      const sessionId = process.env["SESSION_ID"] ?? "unknown";
      const flagDir = path.join(projectDir, "codegen", "llm-pending");
      fs.mkdirSync(flagDir, { recursive: true });
      const flagFile = path.join(flagDir, `${sessionId}.flag`);
      const content = [
        `agent_type=${agentType}`,
        "changed_llm_files:",
        ...llmFiles.map((f) => `  ${f}`),
      ].join("\n");
      fs.writeFileSync(flagFile, content);
      debugLog("post-developer-format", `LLM signal raised: ${flagFile}`);
    }
  });
}
