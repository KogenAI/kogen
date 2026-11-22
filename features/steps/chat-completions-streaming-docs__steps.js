const { When, Then } = require('@cucumber/cucumber');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const PAGE = 'docs/providers.md';
const OBSOLETE = /does not yet stream|arrives whole|whole reply|45[ -]seconds?/i;
const OLD_SENTENCE = 'The Chat Completions route does not yet stream, so a reply arrives whole and the 45 seconds first-byte watchdog applies to the wait for it.';
let binary = null;

function page() {
  return fs.readFileSync(PAGE, 'utf8');
}

function chatLines(text) {
  return text.split('\n').filter((l) => /Chat Completions route/.test(l));
}

When('chat-completions-streaming-docs: the Go test binary of the providers guide is compiled', function () {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ccsd-'));
  binary = path.join(dir, 'cli.test');
  const r = spawnSync('go', ['test', '-c', '-o', binary, '.'], {
    cwd: 'cli',
    encoding: 'utf8',
    timeout: 100000,
    env: { ...process.env, GOFLAGS: '-trimpath' },
  });
  assert.equal(r.status, 0, 'cd cli && go test -c failed (status ' + r.status + '):\n' + (r.stdout || '') + (r.stderr || ''));
});

Then('chat-completions-streaming-docs: the provider guide describes the Chat Completions route as streaming with a first-byte wait that covers 60 seconds and has neither obsolete claim', function () {
  const text = page();
  const lines = chatLines(text);
  assert.equal(lines.length, 1, 'docs/providers.md must have exactly one line about the Chat Completions route; found ' + lines.length);
  assert.match(lines[0], /\bstreams\b/i, 'the Chat Completions line must say the route streams: ' + lines[0]);
  assert.match(lines[0], /60 seconds/, 'the Chat Completions line must say a first byte 60 seconds late is still waited for: ' + lines[0]);
  const bad = text.split('\n').filter((l) => OBSOLETE.test(l));
  assert.deepEqual(bad, [], 'docs/providers.md still holds an obsolete whole-reply or 45-second claim: ' + bad.join(' | '));
});

function runBinary() {
  const r = spawnSync(binary, ['-test.v', '-test.count=1', '-test.run', '^TestProvidersGuide'], {
    cwd: 'cli',
    encoding: 'utf8',
    timeout: 60000,
  });
  return { status: r.status, out: (r.stdout || '') + (r.stderr || '') };
}

Then('chat-completions-streaming-docs: the provider guide Go test passes on the page and fails when either obsolete claim or the streaming guidance is missing', function () {
  assert.ok(binary, 'the Go test binary was not compiled');
  const original = fs.readFileSync(PAGE, 'utf8');
  const command = 'cd cli && <compiled test binary> -test.v -test.run ^TestProvidersGuide';
  try {
    const good = runBinary();
    assert.equal(good.status, 0, command + ' failed on the current page (status ' + good.status + '):\n' + good.out);
    assert.ok(good.out.includes('--- PASS: TestProvidersGuideKeepsTheQwenCloudFacts'), command + ' did not run and pass TestProvidersGuideKeepsTheQwenCloudFacts:\n' + good.out);
    const lines = original.split('\n');
    const at = lines.findIndex((l) => /Chat Completions route/.test(l));
    assert.ok(at >= 0, 'docs/providers.md has no Chat Completions line to mutate');
    const mutations = {
      'the obsolete whole-reply and 45-second sentence in place of the streaming guidance': lines.map((l, i) => (i === at ? OLD_SENTENCE : l)).join('\n'),
      'the streaming guidance removed': lines.filter((_, i) => i !== at).join('\n'),
      'the streaming guidance plus a whole-reply claim': original.trimEnd() + '\nA reply arrives whole.\n',
      'the streaming guidance plus a 45-second first-byte claim': original.trimEnd() + '\nThe 45 seconds first-byte watchdog applies to the wait.\n',
    };
    for (const [name, mutated] of Object.entries(mutations)) {
      fs.writeFileSync(PAGE, mutated);
      const r = runBinary();
      assert.notEqual(r.status, 0, command + ' passed on a page with ' + name + '; the test must reject it:\n' + r.out);
      assert.match(r.out, /--- FAIL: TestProvidersGuide/, command + ' failed without a failing TestProvidersGuide test on a page with ' + name + ':\n' + r.out);
    }
  } finally {
    fs.writeFileSync(PAGE, original);
  }
});
