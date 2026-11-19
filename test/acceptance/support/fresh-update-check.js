// The fake Claude Code the scenarios install stands in for Kogen's pinned runtime, so no role
// start may ask the real distribution for a newer one (LOOP-15, daily update): once a scenario
// has put a runtime at the pinned location, the user's last update check ended just now, unless
// the scenario recorded its own check.
const fs = require('node:fs');
const path = require('node:path');
const { AfterStep } = require('@cucumber/cucumber');

AfterStep(function () {
  if (!this.home) return;
  const root = path.join(this.home, '.kogen', 'claude-code');
  if (!fs.existsSync(path.join(root, '2.1.318', 'claude')) || fs.existsSync(path.join(root, 'harness.json'))) return;
  fs.writeFileSync(path.join(root, 'harness.json'), `${JSON.stringify({ checked_at: new Date().toISOString().replace(/\.\d+Z$/, 'Z') })}\n`);
});
