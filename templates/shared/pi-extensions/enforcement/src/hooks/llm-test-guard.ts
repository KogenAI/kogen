/**
 * llm-test-guard.ts — Pi enforcement: deny unbounded `mix test --only llm_integration`.
 *
 * Mirrors: templates/shared/hooks/llm-test-guard.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, debugLog } from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "llm-test-guard",
  event: "tool_call",
  matcher: "bash",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;

    const command: string =
      (event.input as { command?: string }).command ?? "";
    debugLog("llm-test-guard", `cmd=${command}`);

    if (
      !/mix\s+test.*--only\s+llm_integration|mix\s+test.*--only=llm_integration/.test(
        command
      )
    ) {
      return;
    }

    const hasPartition1 = /MIX_TEST_PARTITION=1\b/.test(command);
    const hasPartitions1 = /MIX_TEST_PARTITIONS=1\b/.test(command);
    const hasExsPath = /[^\s]+\.exs/.test(command);

    if (hasPartition1 && hasPartitions1 && hasExsPath) return;

    return deny(
      "Unbounded `mix test --only llm_integration` runs the LLM suite without partitioning. Use `make llm` (10-partition parallel) for the full suite, or `make llm-single FILE=test/.../foo_test.exs` for one file."
    );
  });
}
