const { When, Then } = require('@cucumber/cucumber');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { spawnSync } = require('node:child_process');

const LABEL = 'experimental: Build verified with Claude Review; Shape and Review not qualified';
let goRun = null;

// The page as it was at the base commit e24fe68, before the sentence was added. Kogen's clean
// verification runs with a synthetic HEAD that already holds the candidate page, so the base page
// is carried here instead of being read from Git history.
const BASE_PAGE_LINES = [
  "# Providers",
  "",
  "This page compares every provider name that `kogen provider login` accepts. The names come from `cli/main.go`, and a Go test in `cli/` fails when a name is missing from the table.",
  "A role is marked verified only when the same cell names a qualification record, a path in this repository that exists. Every other role is marked not qualified.",
  "A qualification record is not a promise of access or availability; it names the exact evidence behind one role.",
  "",
  "| Provider | Account or key needed | Roles verified | Built in or custom endpoint | Setup |",
  "| --- | --- | --- | --- | --- |",
  "| `chatgpt` | ChatGPT account, browser sign-in | Shape: verified (`spec/reference/model-family-qualification.md`); Build: verified (`spec/reference/model-family-qualification.md`); Review: verified (`spec/reference/model-family-qualification.md`) | Built in | [Sign in](getting-started.md#2-sign-in) |",
  "| `supergrok` | SuperGrok subscription | Shape: not qualified; Build: not qualified; Review: not qualified | Built in | [Sign in](getting-started.md#2-sign-in) |",
  "| `opencode-go` | OpenCode Go subscription | Shape: not qualified; Build: not qualified; Review: not qualified | Built in | [Sign in](getting-started.md#2-sign-in) |",
  "| `anthropic` | Anthropic API key on stdin | Shape: not qualified; Build: not qualified; Review: verified (`spec/reference/model-family-qualification.md`) | Built in | [Sign in](getting-started.md#2-sign-in) |",
  "| `claude-code` | Claude subscription, signed in through Kogen's pinned Claude Code | Shape: not qualified; Build: not qualified; Review: not qualified | Built in | [Sign in](getting-started.md#2-sign-in) |",
  "| `openai-compatible` | Base URL and key of the host | Shape: not qualified; Build: not qualified; Review: not qualified | Custom endpoint | [openai-compatible](#openai-compatible) |",
  "",
  "## openai-compatible",
  "",
  "`openai-compatible` talks to a host you choose. Kogen has no qualification record for any compatible host, so every role of this provider is not qualified, whatever the host advertises.",
  "Run `kogen provider login openai-compatible`, enter the base URL on line 1 and the key on line 2, then set the role in `.kogen/models.yaml` with `provider: openai-compatible`, a `base_url`, a `model` and an `effort`.",
  "See [configuration.md](configuration.md) for the lineup file.",
  "",
  "### QwenCloud",
  "",
  "experimental: Build verified with Claude Review; Shape and Review not qualified",
  "",
  "The label above is not a qualification record. No file in this repository records it, so the table keeps every role of `openai-compatible` as not qualified.",
  "",
  "Setup, guided: run `kogen provider login` on an interactive terminal and choose QwenCloud.",
  "",
  "1. It asks `Token Plan or pay-as-you-go?`. Token Plan uses the base URL below; pay-as-you-go uses the Singapore one.",
  "2. For Token Plan it prints one warning that the plan's terms restrict automation and non-interactive batch use.",
  "3. It asks only for the key (`API key:`, never echoed), then prints the lineup it would write and asks `Save this login and lineup? [y/N]`.",
  "4. Only `y` saves: the key as the `openai-compatible` login bound to the base URL's origin, and this build role in `.kogen/models.yaml`, with the shape and review roles left as they are. Any other answer saves nothing.",
  "",
  "```yaml",
  "build: {provider: openai-compatible, base_url: https://token-plan.maas.qwencloudapi.com/compatible-mode/v1, model: qwen4-max, effort: high}",
  "```",
  "",
  "The guided flow writes the same role in block form. The Singapore pay-as-you-go base URL is `https://ap-southeast-1.maas.qwencloudapi.com/compatible-mode/v1`.",
  "",
  "The direct form is unchanged for scripts and agents: `kogen provider login openai-compatible` reads the base URL on line 1 and the key on line 2 from stdin, and you add the role to `.kogen/models.yaml` yourself.",
  "The guided flow makes no network call.",
  "",
  "Honesty note: Token Plan terms restrict automation and non-interactive batch use, so read them before you choose between a Token Plan and pay-as-you-go.",
  "The Chat Completions route does not yet stream, so a reply arrives whole and the 45 seconds first-byte watchdog applies to the wait for it.",
  "",
];

function page() {
  return fs.readFileSync('docs/providers.md', 'utf8');
}

function qwenSection(text) {
  const start = text.indexOf('### QwenCloud\n');
  assert.ok(start >= 0, 'docs/providers.md must keep the "### QwenCloud" section');
  const rest = text.slice(start + '### QwenCloud\n'.length);
  const next = rest.search(/^#/m);
  return next >= 0 ? rest.slice(0, next) : rest;
}

When('docs-provider-qwen-proxy-evidence: the Go tests of the providers guide are run', function () {
  goRun = spawnSync('go', ['test', '-count=1', '-v', '-run', '^TestProvidersGuide', '.'], {
    cwd: 'cli',
    encoding: 'utf8',
    timeout: 100000,
    env: { ...process.env, GOFLAGS: '-trimpath' },
  });
});

Then('docs-provider-qwen-proxy-evidence: the QwenCloud section has one sentence directly after the label line that names the fleet proxy and says the direct public-install Build is still under test, before the setup example', function () {
  const lines = qwenSection(page()).split('\n');
  const label = lines.indexOf(LABEL);
  assert.ok(label >= 0, 'the QwenCloud section must keep the label line');
  const fence = lines.findIndex((l) => l.startsWith('```'));
  assert.ok(fence > label, 'the QwenCloud section must keep its setup example after the label line');
  const between = lines.slice(label + 1, fence).filter((l) => l.trim() !== '');
  const hits = between.filter((l) => /fleet proxy/i.test(l));
  assert.equal(hits.length, 1, 'exactly one text line between the label line and the setup example must name the fleet proxy; found ' + hits.length);
  assert.equal(between[0], hits[0], 'the sentence must come directly after the label line, before any other text: ' + between[0]);
  const sentence = hits[0].trim().replace(/\s+/g, ' ');
  assert.match(sentence, /direct public-install build/i, 'the sentence must mention the direct public-install Build: ' + sentence);
  assert.match(sentence, /still under test/i, 'the sentence must say the direct public-install Build is still under test: ' + sentence);
  assert.ok(!/[.!?]\s+\S/.test(sentence), 'the line must be one sentence: ' + sentence);
  assert.equal(page().toLowerCase().split('fleet proxy').length - 1, 1, 'the page must name the fleet proxy once');
});

Then('docs-provider-qwen-proxy-evidence: the Go tests of the providers guide passed and the Go test file covers the fleet proxy sentence', function () {
  assert.ok(goRun, 'the Go tests were not run');
  const out = (goRun.stdout || '') + (goRun.stderr || '');
  const command = 'cd cli && go test -count=1 -v -run ^TestProvidersGuide . (status ' + goRun.status + ')';
  assert.equal(goRun.status, 0, command + ' failed:\n' + out);
  for (const name of ['TestProvidersGuideHasARowForEveryAcceptedProvider', 'TestProvidersGuideKeepsTheQwenCloudFacts']) {
    assert.ok(out.includes('--- PASS: ' + name), command + ' did not run and pass ' + name + ':\n' + out);
  }
  const testFile = fs.readFileSync('cli/providers_guide_test.go', 'utf8');
  assert.match(testFile, /fleet proxy/i, 'cli/providers_guide_test.go must check the fleet proxy sentence');
});

Then('docs-provider-qwen-proxy-evidence: no other line of the page was reworded or removed and no emoji was added', function () {
  const now = page().split('\n');
  const before = BASE_PAGE_LINES;
  const remaining = new Map();
  for (const l of now) remaining.set(l, (remaining.get(l) || 0) + 1);
  for (const l of before) {
    const n = remaining.get(l) || 0;
    assert.ok(n > 0 || l === '', 'an original line was reworded or removed: ' + l);
    if (n > 0) remaining.set(l, n - 1);
  }
  const added = now.filter((l) => l.trim() !== '').length - before.filter((l) => l.trim() !== '').length;
  assert.equal(added, 1, 'exactly one non-blank line must be added to the page; added ' + added);
  assert.ok(!/\p{Extended_Pictographic}/u.test(page()), 'the page must contain no emoji');
});
