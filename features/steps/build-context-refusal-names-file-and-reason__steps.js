const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { Given, When, Then } = require('@cucumber/cucumber');

const P = 'build-context-refusal-names-file-and-reason: ';
const root = process.cwd();

// A scratch Go test, injected into package main through a go build overlay so that the checkout
// is not touched. It runs the real CLI entry (run, through the existing runCaptured helper) in a
// temporary folder and records the exit code, stdout and the folder.
const PROBE = `package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestKogenAcceptanceContextProbe(t *testing.T) {
	kind, name, out := os.Getenv("KOGEN_ACC_KIND"), os.Getenv("KOGEN_ACC_FILE"), os.Getenv("KOGEN_ACC_OUT")
	dir := t.TempDir()
	wd, _ := os.Getwd()
	if err := os.Chdir(dir); err != nil {
		t.Fatal(err)
	}
	defer os.Chdir(wd)
	t.Setenv("KOGEN_PROVIDER_URL", "http://127.0.0.1:1")
	t.Setenv("KOGEN_AUTH_URL", "http://127.0.0.1:1")
	var err error
	switch kind {
	case "missing":
	case "directory":
		err = os.Mkdir(name, 0o755)
	case "oversize":
		err = os.WriteFile(name, []byte(strings.Repeat("a", 262145)), 0o644)
	case "exact":
		err = os.WriteFile(name, []byte(strings.Repeat("a", 262144)), 0o644)
	case "blank":
		err = os.WriteFile(name, []byte("  \\n"), 0o644)
	case "binary":
		err = os.WriteFile(name, []byte{0xff, 0xfe}, 0o644)
	default:
		t.Fatal("unknown kind " + kind)
	}
	if err != nil {
		t.Fatal(err)
	}
	cwd, _ := os.Getwd()
	code, stdout := runCaptured(t, "intent", "build", "is-even", "--context", name)
	data, _ := json.Marshal(map[string]any{"dir": cwd, "code": code, "stdout": stdout, "joined": filepath.Join(cwd, name)})
	if err := os.WriteFile(out, data, 0o644); err != nil {
		t.Fatal(err)
	}
}
`;

function probe(kind, name) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'ctx-acc-'));
  const testFile = path.join(tmp, 'probe_test.go');
  fs.writeFileSync(testFile, PROBE);
  const overlay = path.join(tmp, 'overlay.json');
  fs.writeFileSync(overlay, JSON.stringify({ Replace: { [path.join(root, 'cli', 'zz_kogen_acceptance_context_test.go')]: testFile } }));
  const out = path.join(tmp, 'out.json');
  const r = spawnSync('go', ['test', `-overlay=${overlay}`, '-count=1', '-vet=off', '-run', '^TestKogenAcceptanceContextProbe$', '.'], {
    cwd: path.join(root, 'cli'), encoding: 'utf8', timeout: 100000,
    env: { ...process.env, KOGEN_ACC_KIND: kind, KOGEN_ACC_FILE: name, KOGEN_ACC_OUT: out }
  });
  assert.equal(r.status, 0, `go test (probe ${kind} ${name}) failed: ${r.stdout}${r.stderr}`);
  return JSON.parse(fs.readFileSync(out, 'utf8'));
}

Given(P + 'the kogen command line package is present', function () {
  assert.ok(fs.existsSync(path.join(root, 'cli', 'main.go')), 'cli/main.go is missing');
});

When(P + 'the context option names a {string} file {string}', function (kind, name) {
  this.result = probe(kind, name);
});

Then(P + 'the exit code is {int}', function (code) {
  assert.equal(this.result.code, code, `stdout was ${JSON.stringify(this.result.stdout)}`);
});

Then(P + 'the refusal line is exactly {string}', function (line) {
  const want = line.split('<dir>').join(this.result.dir) + '\n';
  assert.equal(this.result.stdout, want);
});

Then(P + 'stdout does not contain {string}', function (text) {
  assert.ok(!this.result.stdout.includes(text), `stdout contained ${text}: ${JSON.stringify(this.result.stdout)}`);
});

Then(P + 'the troubleshooting guide has a context_unavailable entry with the six causes and the working folder', function () {
  const doc = fs.readFileSync(path.join(root, 'docs', 'troubleshooting.md'), 'utf8');
  assert.ok(doc.includes('intent/context_unavailable'), 'docs/troubleshooting.md has no intent/context_unavailable entry');
  for (const cause of ['not found', 'not a regular file', 'unreadable', 'larger than 262144 bytes', 'not valid UTF-8', 'blank']) {
    assert.ok(doc.includes('`' + cause + '`'), `docs/troubleshooting.md does not list the cause ${cause}`);
  }
  assert.match(doc, /folder where you ran `kogen`/, 'docs/troubleshooting.md does not say the path is resolved against the folder where kogen was run');
});
