const { Then } = require('@cucumber/cucumber');
const assert = require('node:assert/strict');
const fs = require('node:fs');
function section() {
  const text = fs.readFileSync('docs/getting-started.md', 'utf8');
  const match = text.match(/^## 3\. Log in\s*\n([\s\S]*?)(?=^## |$(?![\s\S]))/m);
  assert.ok(match, 'docs/getting-started.md must retain step 3');
  return match[1];
}
Then('docs-unattended-sign-in: step 3 contains these literal instructions', function (table) {
  const text = section();
  for (const [expected] of table.raw()) assert.ok(text.includes(expected), `step 3 missing: ${expected}`);
});
Then('docs-unattended-sign-in: step 3 explains these requirements', function (table) {
  const text = section().replace(/[`*_]/g, '').replace(/\s+/g, ' ');
  for (const [expected] of table.raw()) assert.ok(text.toLowerCase().includes(expected.toLowerCase()), `step 3 missing explanation: ${expected}`);
});
