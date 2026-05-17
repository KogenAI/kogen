/**
 * dev-no-ci.ts — Pi enforcement: deny gate commands for developer-* agents.
 *
 * Mirrors: templates/shared/hooks/dev-no-ci.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, parseAgentType, debugLog } from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "dev-no-ci",
  event: "tool_call",
  matcher: "bash",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;

    const agentType = parseAgentType();
    if (!/^developer-/.test(agentType)) return;

    const command: string =
      (event.input as { command?: string }).command ?? "";
    debugLog("dev-no-ci", `agent=${agentType} cmd=${command}`);

    // Deny: make ci / ci-fast / ci-cover / predeploy / llm / llm-phoenix / llm-all
    if (
      /^\s*make\s+(ci|ci-fast|ci-cover|predeploy|llm|llm-phoenix|llm-all)(\s|$)/.test(
        command
      )
    ) {
      return deny(
        "Dev MUST NOT run gate commands. The dev-gate.sh SubagentStop hook runs the gate after you exit. Specific test files are OK: `mix test test/path/file.exs`."
      );
    }

    // Deny: coverage flags / mix coveralls
    if (
      /(^|\s)--cover(\s|$)|\bcoveralls\.(html|json)\b|\bmix\s+coveralls\b/.test(
        command
      )
    ) {
      return deny(
        "Dev MUST NOT run coverage (--cover, coveralls.html, coveralls.json, mix coveralls). Coverage runs the full suite — the dev-gate.sh SubagentStop hook handles it after you exit."
      );
    }

    // Deny: bare `mix test`
    if (/^\s*mix\s+test\s*$/.test(command)) {
      return deny(
        "Bare `mix test` runs full suite — dev MUST NOT. Use `mix test test/path/file.exs` for specific files."
      );
    }

    // Deny: `mix test` with only flags (no path)
    if (/^\s*mix\s+test\s+--/.test(command)) {
      const hasPath = /[^\s]+\.exs|[^\s]+\/[^\s]+/.test(command.replace(/^\s*mix\s+test\s+/, ""));
      if (!hasPath) {
        return deny(
          "`mix test` with only flags (no path) runs full suite — dev MUST NOT. Specify a test file path, e.g. `mix test test/path/file.exs`."
        );
      }
    }
  });
}
