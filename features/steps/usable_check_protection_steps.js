const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const REPO = path.resolve(__dirname, '../..');

// This is an independent acceptance harness. Only the external provider is scripted;
// init, config, readiness, protection, Git, checks and the installed CLI remain real.
if (process.env.KOGEN_PROTECTION_CHILD === '1') {
  require(path.join(REPO, 'test/acceptance/support/world'));
  require(path.join(REPO, 'test/acceptance/support/hooks'));
  const { Given, Then } = require('@cucumber/cucumber');
  const { dispatch } = require(path.join(REPO, 'test/acceptance/support/handlers'));

  function put(world, name, text) {
    const file = path.join(world.project, name);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, text);
  }
  function git(world, args) {
    const r = world.git(world.project, args);
    assert.equal(r.status, 0, r.stdout + r.stderr);
    return r.stdout.trim();
  }
  function commit(world, subject) {
    git(world, ['add', '-A']);
    git(world, ['commit', '-qm', subject]);
  }
  function call(name, args, id) {
    return { type: 'function_call', id: `item_${id}`, call_id: `call_${id}`, name, arguments: JSON.stringify(args) };
  }
  function text(value) {
    return { type: 'message', id: 'item_plan', role: 'assistant', content: [{ type: 'output_text', text: value }] };
  }
  function protection(config) {
    const section = config.split(/^protect:\s*\n/m)[1]?.split(/^models:/m)[0] || '';
    return [...section.matchAll(/^  - '((?:[^']|'')*)'\s*$/gm)].map(m => m[1].replaceAll("''", "'"));
  }
  function checkNames(config) {
    return [...config.matchAll(/^    - name: (.+)$/gm)].map(m => m[1]);
  }
  const mixBefore = `defmodule ExApp.MixProject do
  use Mix.Project

  def project do
    [app: :ex_app, version: "0.1.0", elixir: "~> 1.18", deps: []]
  end
end
`;
  const mixAfter = mixBefore.replace('deps: []', 'deps: [{:local_dep, path: "vendor/local_dep"}]');
  const goBefore = 'module fixture.invalid/cli\n\ngo 1.20\n';
  const goAfter = goBefore + '\nrequire fixture.invalid/localdep v0.0.0\n\nreplace fixture.invalid/localdep => ../vendor/go_dep\n';
  const goChecks = [
    { name: 'go-format', run: 'test -z "$(cd cli && gofmt -l .)"' },
    { name: 'go-test', run: '(cd cli && go test ./...)' },
    { name: 'go-vet', run: '(cd cli && go vet ./...)' },
    { name: 'go-build', run: '(cd cli && go build -o /dev/null ./...)' },
  ];
  const slug = 'add-local-deps';
  function intentFiles() {
    return [
      { path: `.kogen/intents/${slug}/intent.md`, content: `# Add local dependencies

Slug: ${slug}
Model: not applicable — dependency declarations, no application state
Acceptance:
- .kogen/intents/${slug}/acceptance.feature
- features/steps/dependency_steps.js

Add the existing local dependencies to mix.exs and cli/go.mod without changing checks.

## Decisions
- Use the existing local dependency projects. (source: request)

## Tests
- Both manifests declare the local dependencies: the dependency acceptance scenario (integration)

## Feasibility
- none
` },
      { path: `.kogen/intents/${slug}/acceptance.feature`, content: `Feature: Local dependencies
  Scenario: Declare both local dependencies
    Then file "mix.exs" contains '{:local_dep, path: "vendor/local_dep"}'
    And file "cli/go.mod" contains "require fixture.invalid/localdep v0.0.0"
` },
      { path: 'features/steps/dependency_steps.js', content: `const { Then } = require('@cucumber/cucumber');
const fs = require('node:fs');
const assert = require('node:assert/strict');
Then('file {string} contains {string}', function (file, value) {
  assert.ok(fs.readFileSync(file, 'utf8').includes(value), file + ' lacks ' + value);
});
` },
    ];
  }

  Given('the installed protection qualification has run', { timeout: 240000 }, async function () {
    const mode = process.env.KOGEN_PROTECTION_MODE;
    const npm = mode === 'npm-scripts';
    await this.createProject(npm ? 'node-app' : 'ex-app');
    // Keep the existing fixture toolchain isolation, extending it only for real Go.
    const { findProgram } = require(path.join(REPO, 'test/acceptance/support/world'));
    if (!npm) {
      const go = findProgram('go');
      assert.ok(go, 'Go is required for the Mix/nested-Go regression');
      this.toolPath = path.dirname(go);
      put(this, 'mix.exs', mixBefore);
      // The ex-app detection fixture deliberately contains a compile warning.
      // This regression requires all seven baseline checks to pass.
      put(this, 'lib/ex_app.ex', 'defmodule ExApp do\n  def double(n), do: n * 2\nend\n');
      put(this, 'cli/go.mod', goBefore);
      put(this, 'cli/main.go', 'package main\n\nfunc main() {}\n');
      put(this, 'cli/main_test.go', 'package main\n\nimport "testing"\n\nfunc TestMain(t *testing.T) { main() }\n');
      put(this, 'vendor/local_dep/mix.exs', `defmodule LocalDep.MixProject do
  use Mix.Project
  def project, do: [app: :local_dep, version: "0.1.0"]
end
`);
      put(this, 'vendor/local_dep/lib/local_dep.ex', 'defmodule LocalDep do\n  def value, do: :ok\nend\n');
      put(this, 'vendor/go_dep/go.mod', 'module fixture.invalid/localdep\n\ngo 1.20\n');
      put(this, 'vendor/go_dep/dep.go', 'package localdep\n\nconst Value = 1\n');
      put(this, '.gitignore', '/_build/\n/deps/\n/cli/cli\n');
      put(this, 'README.md', '# Mix and nested Go project\n\nSetup: `mix deps.get`. Format: `mix format`.\nChecks: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`.\nGo checks: ' + goChecks.map(c => '`' + c.run + '`').join(', ') + '.\n');
      commit(this, 'Prepare local Mix and Go dependency fixture');
    }
    await dispatch(this, '^the caller is signed in to ChatGPT$', []);
    this.server.configure('independent-protection');
    this.server.scriptResponse = (record, ordinal) => {
      if (record.kind === 'init') {
        const protect = npm ? ['package.json'] : ordinal === 1 ? ['.formatter.exs', 'mix.exs', 'cli/go.mod'] : ['.formatter.exs'];
        return { items: [call('submit_configuration', { setup: [], fix: [], checks: npm ? [] : goChecks, protect }, `init_${ordinal}`)] };
      }
      if (record.kind === 'shape') {
        if (mode === 'manual-mix' || npm) {
          return { items: [call('submit', { blocked: { paths: [npm ? 'package.json' : 'mix.exs'], reason: 'The requested dependency edit requires changing this whole-file protected manifest.' } }, `blocked_${ordinal}`)] };
        }
        return { items: [call('submit', { files: intentFiles() }, `shape_${ordinal}`)] };
      }
      if (record.kind === 'plan') return { items: [text('Add the existing local dependencies and preserve every check and protected file.')] };
      if (record.kind === 'review') return { items: [call('submit_review', { verdict: 'approve', findings: [] }, `review_${ordinal}`)] };
      if (record.kind === 'build') {
        // Also terminates the unfixed version: bypassing write_file with shell must
        // hit its real baseline guard rather than retry forever after a refusal.
        if (mode === 'formatter') return { items: [call('shell', { command: "printf '\\n# changed during Build\\n' >> .formatter.exs" }, `mutate_${ordinal}`)] };
        const previous = (record.body.input || []).filter(i => i.type === 'function_call_output').map(i => String(i.output)).join('\n');
        if (previous.includes('refused:')) return { items: [call('shell', { command: "printf '\\n# changed dependency manifest\\n' >> mix.exs" }, `force_${ordinal}`)] };
        return { items: [call('write_file', { path: 'mix.exs', content: mixAfter }, `mix_${ordinal}`), call('write_file', { path: 'cli/go.mod', content: goAfter }, `go_${ordinal}`), call('finish', { summary: 'Declared both local dependencies.' }, `finish_${ordinal}`)] };
      }
      throw new Error('Unexpected provider request kind: ' + record.kind);
    };
    const receipt = { commands: {} };
    const observe = (name, result) => { receipt.commands[name] = { code: result.code, stdout: result.stdout, stderr: result.stderr }; };
    const init = await this.invoke('kogen init');
    observe('init', init);
    receipt.initCode = init.code;
    const initRequests = this.server.requests.filter(r => r.kind === 'init');
    receipt.initCalls = initRequests.length;
    const feedback = initRequests[1]?.body.input?.filter(i => i.type === 'function_call_output').map(i => i.output).join('\n') || '';
    receipt.correctionNamesPaths = feedback.includes('mix.exs') && feedback.includes('cli/go.mod');
    if (init.code !== 0) { this.protectionReceipt = receipt; return; }
    if (mode === 'manual-mix') {
      const file = '.kogen/project.yaml';
      put(this, file, fs.readFileSync(path.join(this.project, file), 'utf8').replace("  - '.formatter.exs'", "  - '.formatter.exs'\n  - 'mix.exs'"));
      commit(this, 'Explicitly protect the Mix manifest');
    }
    const config = fs.readFileSync(path.join(this.project, '.kogen/project.yaml'), 'utf8');
    const formatter = npm ? null : fs.readFileSync(path.join(this.project, '.formatter.exs'), 'utf8');
    const head = this.head();
    receipt.protect = protection(config);
    receipt.checks = checkNames(config);
    const shape = await this.invoke(`kogen intent shape ${slug} -`, { stdin: npm ? 'Add a dependency to package.json while preserving the npm check scripts.' : 'Add the existing local dependencies to mix.exs and cli/go.mod; preserve checks and formatter settings.' });
    observe('shape', shape);
    receipt.shapeCode = shape.code;
    const requests = this.server.requests.filter(r => r.kind === 'shape');
    const first = requests[0];
    // Context is a public external-provider input, not a private helper assertion.
    const userContext = (first?.body.input || []).filter(i => i.role === 'user').map(i => i.content).join('\n');
    const protectLines = userContext.split('\n').filter(line => /protect|protected/i.test(line)).join('\n');
    receipt.contextHasProtect = receipt.protect.every(p => protectLines.includes(p));
    receipt.blockedTool = Boolean(first?.body.tools?.find(t => t.name === 'submit')?.parameters?.properties?.blocked);
    receipt.conflict = shape.stdout.split('\n').find(line => line.startsWith('shape/protected_conflict:')) || '';
    receipt.nextAction = shape.stdout.split('\n').find(line => line.startsWith('Next: revise the request,')) || '';
    receipt.noReady = !shape.stdout.includes(`Next: kogen intent approve ${slug}`);
    receipt.noIntent = !fs.existsSync(path.join(this.project, `.kogen/intents/${slug}/intent.md`));
    receipt.noApproval = !fs.existsSync(path.join(this.project, `.kogen/local/approvals/${slug}.json`));
    receipt.noBuild = !this.server.requests.some(r => ['plan', 'build', 'review'].includes(r.kind));
    if (shape.code === 0 && !npm && mode !== 'manual-mix') {
      const card = await this.invoke(`kogen intent approve ${slug}`);
      assert.equal(card.code, 5, card.stdout + card.stderr);
      const hash = card.stdout.match(/^SHA-256: ([a-f0-9]{64})$/m)?.[1];
      assert.ok(hash, 'approval card lacks SHA-256');
      const approval = await this.invoke(`kogen intent approve ${slug} ${hash}`);
      receipt.approvalCode = approval.code;
      if (approval.code === 0) {
        const build = await this.invoke(`kogen intent build ${slug}`);
        observe('build', build);
        receipt.buildCode = build.code;
        receipt.landed = build.stdout.includes(`landed ${slug}`) && this.head() !== head;
        receipt.baselineChanged = build.stdout.includes('candidate/baseline_changed:') && build.stdout.includes('.formatter.exs');
        const line = build.stdout.split('\n').find(l => l.trimStart().startsWith('checks: ')) || '';
        receipt.verified = line.replace(/^\s*checks: /, '').split(', ').filter(v => v !== 'model not applicable');
        receipt.reviewApproved = this.server.responseItems.some(i => i.kind === 'review' && i.name === 'submit_review' && i.args.verdict === 'approve');
      }
    }
    receipt.manifestsChanged = !npm && fs.readFileSync(path.join(this.project, 'mix.exs'), 'utf8').includes('{:local_dep, path: "vendor/local_dep"}') && fs.readFileSync(path.join(this.project, 'cli/go.mod'), 'utf8').includes('require fixture.invalid/localdep v0.0.0');
    receipt.headUnchanged = this.head() === head;
    receipt.configUnchanged = fs.readFileSync(path.join(this.project, '.kogen/project.yaml'), 'utf8') === config;
    receipt.formatterUnchanged = npm || fs.readFileSync(path.join(this.project, '.formatter.exs'), 'utf8') === formatter;
    this.protectionReceipt = receipt;
  });
  Then('the installed protection qualification records its observations', function () {
    fs.writeFileSync(process.env.KOGEN_PROTECTION_RECEIPT, JSON.stringify(this.protectionReceipt));
  });
} else {
  const { When, Then } = require('@cucumber/cucumber');
  When('I qualify check protection with the installed release in mode {string}', { timeout: 300000 }, async function (mode) {
    const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-protection-harness-'));
    this.protectionTemp = temp;
    const feature = path.join(temp, 'qualification.feature');
    const receipt = path.join(temp, 'receipt.json');
    fs.writeFileSync(feature, 'Feature: Installed protection boundary\n  Scenario: Qualify protection\n    Given the installed protection qualification has run\n    Then the installed protection qualification records its observations\n');
    const cucumber = path.join(REPO, 'test/acceptance/node_modules/@cucumber/cucumber/bin/cucumber.js');
    const child = spawn(process.execPath, [cucumber, '--strict', '--require', __filename, '--format', 'progress', feature], {
      cwd: REPO,
      env: { ...process.env, KOGEN_PROTECTION_CHILD: '1', KOGEN_PROTECTION_MODE: mode, KOGEN_PROTECTION_RECEIPT: receipt },
      stdio: ['ignore', 'pipe', 'pipe'],
      detached: true,
    });
    let output = '';
    child.stdout.on('data', b => { output += b; });
    child.stderr.on('data', b => { output += b; });
    const timer = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 270000);
    try {
      const code = await new Promise((resolve, reject) => { child.on('error', reject); child.on('close', resolve); });
      assert.equal(code, 0, output);
      this.protectionReceipt = JSON.parse(fs.readFileSync(receipt, 'utf8'));
    } finally {
      clearTimeout(timer);
      fs.rmSync(temp, { recursive: true, force: true });
    }
  });
  Then('the protection qualification receipt contains:', function (table) {
    assert.ok(this.protectionReceipt, 'qualification produced no receipt');
    for (const [key, raw] of table.raw()) {
      let expected;
      try { expected = JSON.parse(raw); } catch { expected = raw; }
      assert.deepEqual(this.protectionReceipt[key], expected, `${key}: ${JSON.stringify(this.protectionReceipt)}`);
    }
  });
}
