/**
 * pi-tool-mapping.ts — Maps Claude Code hook matcher patterns to Pi tool names.
 *
 * Claude hooks use PascalCase tool names (Bash, Edit, Write, Read, etc.).
 * Pi uses lowercase names (bash, edit, write, read, etc.).
 */

/** Maps a Claude-style tool name (or pipe-separated list) to Pi tool names. */
export const CLAUDE_TO_PI_TOOLS: Record<string, string[]> = {
  Bash: ["bash"],
  Edit: ["edit"],
  MultiEdit: ["edit"],
  Write: ["write"],
  Read: ["read"],
  Grep: ["grep"],
  Glob: ["find"],
  Monitor: [],
  Agent: [],
  NotebookEdit: [],
};

/**
 * Resolve a Claude hook matcher string (possibly pipe-separated) to a list of
 * Pi tool names. Returns the union of all mapped tools, deduplicated.
 */
export function claudeMatcherToPiTools(matcher: string): string[] {
  const tokens = matcher.split("|").map((t) => t.trim());
  const piTools = new Set<string>();
  for (const token of tokens) {
    const mapped = CLAUDE_TO_PI_TOOLS[token] ?? [];
    for (const t of mapped) {
      piTools.add(t);
    }
  }
  return Array.from(piTools);
}
