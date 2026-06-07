#!/usr/bin/env node
/**
 * schema-validate.js — JSON Schema validator CLI.
 *
 * Usage:
 *   node schema-validate.js <schema-json-file> <value-json-file>
 *
 * Exit codes:
 *   0 — value is valid
 *   1 — value is invalid (errors on stderr), value JSON parse error, OR validator unavailable
 */

"use strict";

const path = require("path");
const fs = require("fs");

const [schemaFile, valueFile] = process.argv.slice(2);

if (!schemaFile || !valueFile) {
  process.stderr.write(
    "Usage: schema-validate.js <schema-json-file> <value-json-file>\n",
  );
  process.exit(1);
}

// Resolve ajv: prefer CODEGEN_DIR/node_modules, fall back to bare require
let Ajv, Ajv2020;
try {
  const codegenDir = process.env["CODEGEN_DIR"];
  if (codegenDir) {
    Ajv = require(path.join(codegenDir, "node_modules", "ajv"));
    try {
      Ajv2020 = require(
        path.join(codegenDir, "node_modules", "ajv", "dist", "2020"),
      );
    } catch (_) {
      // Ajv2020 may not be present; fall back to default
    }
  } else {
    Ajv = require("ajv");
    try {
      Ajv2020 = require("ajv/dist/2020");
    } catch (_) {
      // optional
    }
  }
} catch (_e) {
  process.stderr.write(
    "[schema-validate] ajv unavailable — cannot verify (run npm install in codegen)\n",
  );
  process.exit(1);
}

// Read and parse schema
let schema;
try {
  schema = JSON.parse(fs.readFileSync(schemaFile, "utf-8"));
} catch (e) {
  process.stderr.write(
    "[schema-validate] schema parse error: " + e.message + "\n",
  );
  process.exit(1);
}

// Read and parse value
let value;
try {
  value = JSON.parse(fs.readFileSync(valueFile, "utf-8"));
} catch (e) {
  process.stderr.write(
    "[schema-validate] value parse error: " + e.message + "\n",
  );
  process.exit(1);
}

// Select Ajv class based on $schema keyword
const schemaId = schema.$schema || "";
const is2020 = schemaId.includes("2020-12");

let ajv;
if (is2020 && Ajv2020) {
  const AjvClass = Ajv2020.default || Ajv2020;
  ajv = new AjvClass({ allErrors: true });
} else {
  const AjvClass = Ajv.default || Ajv;
  ajv = new AjvClass({ allErrors: true });
}

const validate = ajv.compile(schema);
const valid = validate(value);

if (valid) {
  process.exit(0);
} else {
  process.stderr.write(ajv.errorsText(validate.errors) + "\n");
  process.exit(1);
}
