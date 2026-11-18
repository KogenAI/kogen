const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { Given, Then } = require('@cucumber/cucumber');

const root = process.cwd();
const FEATURE = 'spec/features/08-chatgpt.feature';
const ROUTE = 'Route messages-compatible (experimental): an explicit streamed Messages wire sent only to the role\'s base_url; no profile qualifies it, so every model on it is experimental. Local fixtures only; live qualification and account debit reconciliation are still required.';
const RECOMMENDED = 'Recommended ChatGPT defaults: Shape gpt-6.1-sol/high, Build gpt-6.1-sol/medium, Review gpt-6.1-terra/medium (omitted roles keep these defaults).';
const FINAL = 'Other model/effort/role strings and custom routes are experimental, may fail, and are not blocked. Recommended defaults are not qualification. Login status is local only; no credentials refreshed or account checked.';
const COMPAT = [
  'claude-code runtime: Claude Code 2.1.318 not installed',
  'Official compatibility (text/tool input, normal routes only):',
  'chatgpt-sol-6-1: chatgpt/gpt-6.1-sol — https://api.openai.com/v1/responses',
  '  shape/high [go-live-2026-10-24]',
  '  build/medium [go-live-2026-10-24]',
  '  review/high [native-go-sol-review-2026-10-24]',
  'anthropic-sonnet-5-5: anthropic/claude-sonnet-5-5 — https://api.anthropic.com/v1/messages',
  '  review/medium [go-live-2026-10-24]'
];
function status(chatgpt, supergrok, anthropic) {
  return [`chatgpt: ${chatgpt}`, `supergrok: ${supergrok}`, 'opencode-go: not signed in', `anthropic: ${anthropic}`, 'claude-code: not signed in'];
}
const NOT = 'not signed in';
const LOGIN = 'saved login cannot be used; run kogen provider login';
const SCENARIOS = [
  { title: 'Browser login, private credentials and the status command', runs: [status(NOT, NOT, NOT), status('signed in (user@example.com)', NOT, NOT)] },
  { title: 'An incomplete saved login is not reported as signed in', runs: [status(`${LOGIN} chatgpt`, NOT, NOT)] },
  { title: 'SuperGrok status is local and requires Kogen-owned credentials', runs: [status(NOT, 'signed in (grok@example.com)', NOT), status(NOT, `${LOGIN} supergrok`, NOT)] },
  { title: 'Saved native Claude keys are local status rather than verified API access', runs: [status(NOT, NOT, 'key saved (not verified)')] }
];

function read(rel) { return fs.readFileSync(path.join(root, rel), 'utf8'); }

// Steps of the scenario with the title: [{ text, doc }] in order.
function scenarioSteps(title) {
  const lines = read(FEATURE).split(/\r?\n/);
  const start = lines.findIndex(line => line.trim() === `Scenario: ${title}`);
  assert.ok(start >= 0, `${FEATURE} has no scenario "${title}"`);
  const steps = [];
  for (let i = start + 1; i < lines.length; i++) {
    const line = lines[i].trim();
    if (/^(@|Scenario)/.test(line)) break;
    const match = line.match(/^(?:Given|When|Then|And|But) (.*)$/);
    if (!match) continue;
    const step = { text: match[1], doc: undefined };
    if ((lines[i + 1] || '').trim() === '"""') {
      const indent = lines[i + 1].match(/^\s*/)[0].length;
      let j = i + 2;
      const body = [];
      while (j < lines.length && lines[j].trim() !== '"""') { body.push(lines[j].slice(indent)); j++; }
      step.doc = body.join('\n');
      i = j;
    }
    steps.push(step);
  }
  return steps;
}

// The stdout assertions after each "kogen provider list" run, in order.
function groups(title) {
  const result = [];
  for (const step of scenarioSteps(title)) {
    if (step.text === 'the caller runs "kogen provider list"') result.push([]);
    else if (/^the caller runs /.test(step.text)) result.push(null);
    else if (/^stdout /.test(step.text) && result.length && result[result.length - 1]) result[result.length - 1].push(step);
  }
  return result.filter(Boolean);
}

// Independent replay of one stdout assertion with the harness semantics.
function replay(step, stdout) {
  if (step.text === 'stdout is:') {
    assert.equal(stdout.replace(/\r?\n$/, ''), step.doc, 'stdout was not exact');
    return;
  }
  if (step.text === 'stdout contains:') {
    assert.ok(stdout.includes(step.doc), 'stdout did not contain the block');
    return;
  }
  let match = step.text.match(/^stdout contains "((?:[^"\\]|\\.)*)"$/);
  if (match) {
    assert.ok(stdout.includes(match[1].replace(/\\"/g, '"')), `stdout did not contain ${match[1]}`);
    return;
  }
  match = step.text.match(/^stdout matches "((?:[^"\\]|\\.)*)"$/);
  if (match) {
    const source = match[1].replace(/\\"/g, '"').replace(/\\'/g, "'").replace(/\$$/, '(?:\\r?\\n)?$');
    assert.match(stdout, new RegExp(source));
    return;
  }
  throw new Error(`unsupported stdout assertion: ${step.text}`);
}
function attempt(assertions, stdout) {
  try { for (const step of assertions) replay(step, stdout); return null; } catch (error) { return error; }
}

function output(run, middle) {
  return [...run, ...COMPAT, RECOMMENDED, ...middle, FINAL].join('\n') + '\n';
}

function eachRun(callback) {
  for (const scenario of SCENARIOS) {
    const found = groups(scenario.title);
    assert.equal(found.length, scenario.runs.length, `scenario "${scenario.title}" must keep ${scenario.runs.length} "kogen provider list" run(s)`);
    found.forEach((assertions, index) => {
      assert.ok(assertions.length > 0, `scenario "${scenario.title}" run ${index + 1} asserts no stdout`);
      callback(assertions, scenario.runs[index], `scenario "${scenario.title}" run ${index + 1}`);
    });
  }
}

Given('spec-provider-list-names-messages-route: the four provider list scenarios are read', function () {
  assert.ok(fs.existsSync(path.join(root, FEATURE)), `${FEATURE} is missing`);
  for (const scenario of SCENARIOS) assert.ok(scenarioSteps(scenario.title).length > 0, `no scenario "${scenario.title}"`);
});

Then('spec-provider-list-names-messages-route: every provider list assertion accepts the output without the Route line', function () {
  eachRun((assertions, run, name) => {
    const failure = attempt(assertions, output(run, []));
    assert.equal(failure, null, `${name} rejected the output without the Route line: ${failure && failure.message}`);
  });
});

Then('spec-provider-list-names-messages-route: every provider list assertion accepts the output with the Route line', function () {
  eachRun((assertions, run, name) => {
    const failure = attempt(assertions, output(run, [ROUTE]));
    assert.equal(failure, null, `${name} rejected the output with the Route line: ${failure && failure.message}`);
  });
});

Then('spec-provider-list-names-messages-route: every provider list assertion rejects any other difference', function () {
  const variants = run => {
    const withRoute = output(run, [ROUTE]);
    const plain = output(run, []);
    return {
      'a different line between': output(run, ['Route something-else (experimental): not the Route line.']),
      'a changed Route line': output(run, [ROUTE.replace('every model on it is experimental', 'every model on it is qualified')]),
      'the Route line twice': output(run, [ROUTE, ROUTE]),
      'the Route line and another line': output(run, [ROUTE, 'Another line.']),
      'a blank line between': output(run, ['']),
      'the Route line before the Recommended line': plain.replace(RECOMMENDED, `${ROUTE}\n${RECOMMENDED}`),
      'the Route line after the final sentence': plain + ROUTE + '\n',
      'an extra trailing line': withRoute + 'Extra.\n',
      'a changed Official compatibility line (with Route)': withRoute.replace('review/high [native-go-sol-review-2026-10-24]', 'review/low [native-go-sol-review-2026-10-24]'),
      'a changed Official compatibility line (without Route)': plain.replace('build/medium [go-live-2026-10-24]', 'build/high [go-live-2026-10-24]'),
      'a changed first line': withRoute.replace(run[0], 'chatgpt: signed in (other@example.com)'),
      'a changed provider status line': plain.replace('opencode-go: not signed in', 'opencode-go: signed in'),
      'a changed Recommended line': withRoute.replace('Build gpt-6.1-sol/medium', 'Build gpt-6.1-sol/high'),
      'a changed final sentence': plain.replace('are not blocked', 'are blocked'),
      'a missing final sentence': plain.replace(FINAL + '\n', ''),
      'a missing runtime line': withRoute.replace(COMPAT[0] + '\n', '')
    };
  };
  eachRun((assertions, run, name) => {
    for (const [what, stdout] of Object.entries(variants(run))) {
      assert.ok(attempt(assertions, stdout), `${name} accepted ${what}`);
    }
  });
});

Then('spec-provider-list-names-messages-route: no scenario is removed or skipped and no protected path is edited', function () {
  const text = read(FEATURE);
  assert.equal((text.match(/^\s*Scenario( Outline)?:/gm) || []).length, 23, `${FEATURE} changed its scenario count`);
  assert.ok(!/@(skip|wip|pending|manual|ignore)\b/.test(text), `${FEATURE} has a skip tag`);
  const changed = execFileSync('git', ['status', '--porcelain', '--untracked-files=all'], { cwd: root, encoding: 'utf8' }).split('\n').filter(Boolean).map(line => line.slice(3));
  const forbidden = changed.filter(file => /^(cli\/go\.mod|cli\/go\.sum|cli\/loop-pin\.json|cli\/third_party\/kogen-loop\/|\.kogen\/project\.yaml$|\.kogen\/models\.yaml$)/.test(file));
  assert.deepEqual(forbidden, [], `forbidden paths changed: ${forbidden.join(', ')}`);
});
