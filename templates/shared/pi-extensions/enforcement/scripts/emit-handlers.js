#!/usr/bin/env node
/**
 * emit-handlers.js — Post-build script that scans compiled hook modules
 * and emits dist/handlers.json listing every registered handler's metadata.
 *
 * Each hook module exports `HANDLER_META = { name, event, matcher }`.
 * This script collects them all and writes the JSON to dist/handlers.json.
 */

const fs = require("fs");
const path = require("path");

const distHooksDir = path.join(__dirname, "..", "dist", "hooks");
const outputPath = path.join(__dirname, "..", "dist", "handlers.json");

if (!fs.existsSync(distHooksDir)) {
  console.error(`ERROR: dist/hooks not found. Run 'npm run build' first.`);
  process.exit(1);
}

const handlers = [];

const files = fs.readdirSync(distHooksDir).filter(
  (f) => f.endsWith(".js") && !f.includes("__tests__") && !f.endsWith(".test.js")
);

for (const file of files.sort()) {
  const modulePath = path.join(distHooksDir, file);
  try {
    const mod = require(modulePath);
    if (mod.HANDLER_META) {
      handlers.push(mod.HANDLER_META);
    }
  } catch (err) {
    console.error(`WARNING: could not load ${file}: ${err.message}`);
  }
}

fs.writeFileSync(outputPath, JSON.stringify(handlers, null, 2) + "\n");
console.log(`Wrote ${handlers.length} handlers to ${outputPath}`);
