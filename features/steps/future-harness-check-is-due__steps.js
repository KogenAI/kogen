'use strict';
// Acceptance for treating a future Harness checked_at as due. It adds a throwaway Go test file to
// the claudecode package through `go test -overlay` (nothing is written into the checkout) and
// runs it in that one package, with the ordinary build cache.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { Given, When, Then } = require('@cucumber/cucumber');

const P = 'future-harness-check-is-due: ';
const ROOT = path.resolve(__dirname, '../..');
const PKG = path.join(ROOT, 'cli/internal/claudecode');
const GO_TEST = `package claudecode

import (
	"testing"
	"time"
)

func TestKogenFutureHarnessDue(t *testing.T) {
	now := time.Date(2026, 11, 19, 12, 0, 0, 0, time.UTC)
	h := Harness{CheckedAt: now.Add(time.Hour).Format(time.RFC3339)}
	if !h.due(now) {
		t.Errorf("checked_at one hour after now: due = false, want true")
	}
}
`;

Given(P + 'a throwaway Harness.due test is overlaid on the claudecode package', function () {
  this.fhDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fh-due-'));
  const src = path.join(this.fhDir, 'driver_test.go');
  fs.writeFileSync(src, GO_TEST);
  this.fhOverlay = path.join(this.fhDir, 'overlay.json');
  fs.writeFileSync(this.fhOverlay, JSON.stringify({ Replace: { [path.join(PKG, 'zz_kogen_future_driver_test.go')]: src } }));
});

When(P + 'that test runs in the claudecode package', { timeout: 110000 }, function () {
  const r = spawnSync('go', ['test', '-count=1', '-v', '-run', '^TestKogenFutureHarnessDue$', '-overlay', this.fhOverlay, './internal/claudecode'],
    { cwd: path.join(ROOT, 'cli'), encoding: 'utf8', timeout: 100000 });
  this.fhOut = `${r.stdout || ''}${r.stderr || ''}`;
  this.fhStatus = r.status;
});

Then(P + 'a checked_at one hour later than now is due', function () {
  assert.ok(this.fhOut.includes('--- PASS: TestKogenFutureHarnessDue '),
    `go test -run ^TestKogenFutureHarnessDue$ ./internal/claudecode (exit ${this.fhStatus}) did not pass TestKogenFutureHarnessDue:\n${this.fhOut}`);
});
