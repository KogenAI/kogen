'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
process.env.KOGEN_FULLSCAN_CONTROL = '1';
const { completeReport } = require('./k-fullscan-assembly__gates.js');
const mode = process.argv[2];
if (!['good', 'bad'].includes(mode)) throw new Error('use good or bad');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fullscan-observer-'));
try {
  const modules = process.env.KOGEN_CUCUMBER || path.resolve(__dirname, '../../test/acceptance/node_modules');
  const report = path.join(dir, 'report.json');
  const feature = path.join(dir, 'control.feature');
  const steps = path.join(dir, 'steps.cjs');
  fs.writeFileSync(feature, 'Feature: Report control\n  Scenario: Real runner result\n    Given a control result\n    Then a reached tail\n');
  fs.writeFileSync(steps, `const { Given, Then } = require('@cucumber/cucumber');\nGiven('a control result', function () { if (process.env.FULLSCAN_BAD === '1') throw new Error('known bad'); });\nThen('a reached tail', function () {});\n`);
  const r = spawnSync(process.env.KOGEN_NODE || process.execPath,
    [path.join(modules, '@cucumber/cucumber/bin/cucumber.js'), '--strict', '--require', steps, '--format', `json:${report}`, feature],
    { env: { ...process.env, NODE_PATH: modules, FULLSCAN_BAD: mode === 'bad' ? '1' : '0' }, encoding: 'utf8', timeout: 30000 });
  if (r.error || r.status !== (mode === 'good' ? 0 : 1)) throw new Error(`control runner failed: ${r.error || r.status}\n${r.stdout}\n${r.stderr}`);
  try { completeReport(JSON.parse(fs.readFileSync(report, 'utf8')), 1); }
  catch { console.log('report rejected'); process.exitCode = 1; }
  if (!process.exitCode) console.log('report accepted');
} finally { fs.rmSync(dir, { recursive: true, force: true }); }
