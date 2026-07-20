#!/usr/bin/env node
// index.ts — stdio MCP server bootstrap. Spawned per-session by claude via
// --mcp-config (see harnesses/claude/mcp-server/codegen-mcp.json), one process
// per Claude session — not a hosted/long-lived server.

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { registerAllTools } from "./tools";

async function main() {
  const server = new McpServer({
    name: "codegen",
    version: "0.1.0",
  });

  registerAllTools(server);

  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((err) => {
  process.stderr.write(
    `codegen-mcp-server: fatal: ${err instanceof Error ? err.stack : String(err)}\n`,
  );
  process.exit(1);
});
