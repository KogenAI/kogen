const { When, Then } = require('@cucumber/cucumber');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const PROBE = `package main

import (
	"encoding/json"
	"fmt"
	"os"
	"testing"
)

func TestKogenRejectEmptyProbe(t *testing.T) {
	var args []string
	if err := json.Unmarshal([]byte(os.Getenv("KOGEN_PROBE_ARGS")), &args); err != nil {
		t.Fatal(err)
	}
	inv, _, uerr := parse(args)
	out := map[string]any{}
	if uerr != nil {
		out["usage"] = uerr.msg
	}
	if inv != nil {
		out["project"] = inv.project
		out["output"] = inv.output
		if inv.context != nil {
			out["context"] = *inv.context
		}
	}
	b, _ := json.Marshal(out)
	fmt.Println("KOGEN_PROBE_RESULT " + string(b))
}
`;

let binary = null;
let last = null;

function compile() {
  if (binary) return;
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rec-'));
  const probe = path.join(dir, 'probe.go');
  fs.writeFileSync(probe, PROBE);
  const cli = path.resolve('cli');
  const overlay = path.join(dir, 'overlay.json');
  fs.writeFileSync(overlay, JSON.stringify({ Replace: { [path.join(cli, 'zz_kogen_probe_test.go')]: probe } }));
  const out = path.join(dir, 'cli.test');
  const r = spawnSync('go', ['test', '-c', '-overlay', overlay, '-o', out, '.'], {
    cwd: cli,
    encoding: 'utf8',
    timeout: 100000,
    env: { ...process.env, GOFLAGS: '-trimpath' },
  });
  assert.equal(r.status, 0, 'cd cli && go test -c with the probe overlay failed (status ' + r.status + '):\n' + (r.stdout || '') + (r.stderr || ''));
  binary = out;
}

function tokens(line) {
  // Whitespace separates arguments; '' is one empty argument.
  return line.split(/\s+/).filter((t) => t !== '').map((t) => (t === "''" ? '' : t));
}

When('reject-empty-cli-option-values: kogen parses {string}', function (line) {
  compile();
  const args = tokens(line);
  const r = spawnSync(binary, ['-test.run', '^TestKogenRejectEmptyProbe$', '-test.count=1'], {
    cwd: path.resolve('cli'),
    encoding: 'utf8',
    timeout: 60000,
    env: { ...process.env, KOGEN_PROBE_ARGS: JSON.stringify(args) },
  });
  const text = (r.stdout || '') + (r.stderr || '');
  const m = text.match(/^KOGEN_PROBE_RESULT (.*)$/m);
  assert.ok(r.status === 0 && m, 'the probe of parse(' + JSON.stringify(args) + ') did not report a result (status ' + r.status + '):\n' + text);
  last = JSON.parse(m[1]);
});

Then('reject-empty-cli-option-values: the parse is refused with a usage error that names {string} and says the value is empty', function (option) {
  assert.ok(last, 'no parse was run');
  assert.ok(typeof last.usage === 'string', 'parse returned no usage error: ' + JSON.stringify(last));
  assert.ok(last.usage.includes(option), 'the usage error does not name ' + option + ': ' + last.usage);
  assert.match(last.usage, /empty/i, 'the usage error does not say the value is empty: ' + last.usage);
});

Then('reject-empty-cli-option-values: the usage error is exactly {string}', function (message) {
  assert.ok(last, 'no parse was run');
  assert.equal(last.usage, message);
});

Then('reject-empty-cli-option-values: the parse succeeds', function () {
  assert.ok(last, 'no parse was run');
  assert.equal(last.usage, undefined, 'parse returned a usage error: ' + last.usage);
});

Then('reject-empty-cli-option-values: the parsed project is {string}', function (value) {
  assert.equal(last.project, value);
});

Then('reject-empty-cli-option-values: the parsed context is {string}', function (value) {
  assert.equal(last.context, value);
});

Then('reject-empty-cli-option-values: the parsed output is {string}', function (value) {
  assert.equal(last.output, value);
});
