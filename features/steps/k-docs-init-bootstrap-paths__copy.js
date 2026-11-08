const { Then } = require('@cucumber/cucumber');
const assert = require('node:assert/strict');
const fs = require('node:fs');

Then('k-docs-init-bootstrap-paths: {string} has a paragraph matching {string}', function (doc, pattern) {
  const flags = pattern.startsWith('(?i)') ? 'i' : '';
  const expression = new RegExp(pattern.replace(/^\(\?i\)/, ''), flags);
  const paragraphs = fs.readFileSync(doc, 'utf8').split(/\n\s*\n/).map(p => p.replace(/\s+/g, ' '));
  assert.ok(paragraphs.some(p => expression.test(p)), `${doc}: missing explanation matching ${pattern}`);
});

Then('k-docs-init-bootstrap-paths: {string} contains init contract literal {string}', function (doc, literal) {
  const contract = fs.readFileSync('cli/consumes/kogen-setup/exit_test.go', 'utf8');
  const sourceLiteral = literal === 'environment/no_commits' ? '"environment", "no_commits"' : literal;
  assert.ok(contract.includes(sourceLiteral), `init contract no longer contains ${sourceLiteral}; reconcile docs with init`);
  assert.ok(fs.readFileSync(doc, 'utf8').includes(literal), `${doc}: missing init literal ${literal}`);
});

Then('k-docs-init-bootstrap-paths: {string} does not require a repository with at least one commit', function (doc) {
  assert.doesNotMatch(fs.readFileSync(doc, 'utf8'), /repository (?:of your own )?with at least one commit/i, `${doc}: blanket prerequisite excludes empty-worktree init`);
});
