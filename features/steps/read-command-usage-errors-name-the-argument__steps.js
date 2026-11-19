const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { Given, When, Then } = require('@cucumber/cucumber');

const P = 'read-command-usage-errors-name-the-argument: ';
const root = process.cwd();

// A scratch Go test, injected into package main through a go build overlay so that the checkout
// is not touched. It runs the real command entry (run) with the given words and records the exit
// code and the standard output. The word <project> becomes a fresh Git checkout with a project file.
const PROBE = `package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestKogenAcceptanceReadProbe(t *testing.T) {
	var args []string
	if err := json.Unmarshal([]byte(os.Getenv("KOGEN_ACC_ARGS")), &args); err != nil {
		t.Fatal(err)
	}
	project := t.TempDir()
	if b, e := exec.Command("git", "init", "-q", project).CombinedOutput(); e != nil {
		t.Fatalf("%s: %v", b, e)
	}
	if err := os.MkdirAll(filepath.Join(project, ".kogen/local"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(project, ".kogen/project.yaml"), []byte("fixture"), 0o600); err != nil {
		t.Fatal(err)
	}
	for i, a := range args {
		args[i] = strings.ReplaceAll(a, "<project>", project)
	}
	file, err := os.Create(os.Getenv("KOGEN_ACC_STDOUT"))
	if err != nil {
		t.Fatal(err)
	}
	saved := os.Stdout
	os.Stdout = file
	code := run(args, func() (string, error) { return "", fmt.Errorf("no installation") })
	os.Stdout = saved
	file.Close()
	out, _ := os.ReadFile(os.Getenv("KOGEN_ACC_STDOUT"))
	data, _ := json.Marshal(map[string]any{"code": code, "stdout": string(out)})
	if err := os.WriteFile(os.Getenv("KOGEN_ACC_OUT"), data, 0o644); err != nil {
		t.Fatal(err)
	}
}
`;

let built = null;

function build() {
  if (built) return built;
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'read-acc-'));
  const testFile = path.join(tmp, 'probe_test.go');
  fs.writeFileSync(testFile, PROBE);
  const overlay = path.join(tmp, 'overlay.json');
  fs.writeFileSync(overlay, JSON.stringify({ Replace: { [path.join(root, 'cli', 'zz_kogen_acceptance_read_test.go')]: testFile } }));
  const bin = path.join(tmp, 'probe.test');
  const r = spawnSync('go', ['test', '-c', `-overlay=${overlay}`, '-vet=off', '-o', bin, '.'], {
    cwd: path.join(root, 'cli'), encoding: 'utf8', timeout: 110000
  });
  assert.equal(r.status, 0, `go test -c failed: ${r.stdout}${r.stderr}`);
  built = { tmp, bin };
  return built;
}

function probe(words) {
  const b = build();
  const out = path.join(b.tmp, 'out.json');
  const stdout = path.join(b.tmp, 'stdout.txt');
  fs.rmSync(out, { force: true });
  const r = spawnSync(b.bin, ['-test.run', '^TestKogenAcceptanceReadProbe$', '-test.count=1'], {
    cwd: path.join(root, 'cli'), encoding: 'utf8', timeout: 100000,
    env: { ...process.env, KOGEN_ACC_ARGS: JSON.stringify(words), KOGEN_ACC_OUT: out, KOGEN_ACC_STDOUT: stdout }
  });
  assert.equal(r.status, 0, `probe ${JSON.stringify(words)} failed: ${r.stdout}${r.stderr}`);
  return JSON.parse(fs.readFileSync(out, 'utf8'));
}

Given(P + 'the kogen command line package builds for the acceptance probe', function () {
  assert.ok(fs.existsSync(path.join(root, 'cli', 'facts.go')), 'cli/facts.go is missing');
  build();
});

When(P + 'kogen is run with the words {string}', function (line) {
  this.words = line.split(' ');
  this.result = probe(this.words);
  const lines = this.result.stdout.split('\n').filter((l) => l !== '');
  assert.equal(lines.length, 1, `expected one JSON line for ${JSON.stringify(this.words)}, got ${JSON.stringify(this.result.stdout)}`);
  this.answer = JSON.parse(lines[0]);
});

Then(P + 'the error detail is exactly {string}', function (detail) {
  assert.ok(this.answer.error, `no error in ${this.result.stdout}`);
  assert.equal(this.answer.error.detail, detail);
});

Then(P + 'the exit code is {int} and the error has only the class intent, the reason invalid_argument, the detail and no paths', function (code) {
  assert.equal(this.result.code, code, `stdout was ${JSON.stringify(this.result.stdout)}`);
  const e = this.answer.error;
  assert.deepEqual(Object.keys(e).sort(), ['class', 'detail', 'paths', 'reason']);
  assert.equal(e.class, 'intent');
  assert.equal(e.reason, 'invalid_argument');
  assert.deepEqual(e.paths, []);
  assert.equal(this.answer.data, null);
});
