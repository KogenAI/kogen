const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { Given, Then } = require('@cucumber/cucumber');

const root = process.cwd();
const INIT_TITLE = 'Two invalid configuration replies end init without writing anything';
const TOOL_TITLE = 'A missing project tool is reported after setup and before any model request';
const MUTATION_TITLE = 'A Shape or Refine checkout index or HEAD mutation stops before publication';
const FILES = {
  setup: 'spec/features/01-project-setup.feature',
  building: 'spec/features/04-building.feature',
  lineup: 'spec/features/claude-code-full-lineup.feature'
};

function read(rel) { return fs.readFileSync(path.join(root, rel), 'utf8'); }

// Steps of the scenario with the title: [{ text, doc }] in order.
function scenarioSteps(rel, title) {
  const lines = read(rel).split(/\r?\n/);
  const start = lines.findIndex(line => line.trim() === `Scenario: ${title}`);
  assert.ok(start >= 0, `${rel} has no scenario "${title}"`);
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
  assert.ok(steps.length > 0, `scenario "${title}" has no steps`);
  return steps;
}

function has(steps, text) { return steps.some(step => step.text === text); }
function need(steps, title, text) { assert.ok(has(steps, text), `scenario "${title}" lost the step: ${text}`); }
function mentions(steps, needle) { return steps.some(step => step.text.includes(needle) || (step.doc || '').includes(needle)); }

function escapeRegex(text) { return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }

// Independent replay of the stdout and exit-code assertions (contains and exit code forms) of a scenario.
function check(steps, result, project) {
  let replayed = 0;
  for (const step of steps) {
    const code = step.text.match(/^the exit code is (\d+)$/);
    if (code) {
      assert.equal(result.code, Number(code[1]), `exit code ${result.code}`);
      replayed++;
      continue;
    }
    if (/^stdout is:?/.test(step.text)) throw new Error('exact stdout comparison is not tolerant');
    const contains = step.text.match(/^stdout contains "([^"]*)"$/);
    if (!contains) continue;
    let source = '';
    let at = 0;
    for (const token of contains[1].matchAll(/\{(id8|abs:([^}]+))\}/g)) {
      source += escapeRegex(contains[1].slice(at, token.index));
      source += token[1] === 'id8' ? '[0-9a-f]{8}' : escapeRegex(path.resolve(project, token[2]));
      at = token.index + token[0].length;
    }
    source += escapeRegex(contains[1].slice(at));
    assert.ok(new RegExp(source).test(result.stdout), `stdout did not contain ${contains[1]}`);
    replayed++;
  }
  assert.ok(replayed >= 2, 'the scenario replays fewer than 2 exit or stdout assertions');
}
function attempt(steps, result, project) {
  try { check(steps, result, project); return null; } catch (error) { return error; }
}
function accepts(steps, result, project) {
  const failure = attempt(steps, result, project || '/p');
  assert.equal(failure, null, `the assertions rejected valid output: ${failure && failure.message}`);
}
function rejects(steps, result, name, project) {
  assert.ok(attempt(steps, result, project || '/p'), `the assertions accepted ${name}`);
}

const ID = 'abcd1234';
const PROJECT = '/work/project';
function toolOutput(mutate) {
  const runs = `${PROJECT}/.kogen/local/runs`;
  const lines = [
    'environment/tool_missing: ruff is not available',
    '  commands.checks[lint]: ruff check .',
    `  is-even Build ${ID} stopped in startup: tool_missing; candidate: ${PROJECT}; evidence: ${runs}/${ID}; index: ${runs}/${ID}/index-at-start`,
    `  kogen intent inspect ${ID} --project '${PROJECT}'`,
    '  next: install ruff and run the Build again'
  ];
  return (mutate ? mutate(lines) : lines).join('\n') + '\n';
}

Given('qualify-frozen-corrective-consumer: the three consumer feature files are read', function () {
  for (const rel of Object.values(FILES)) assert.ok(fs.existsSync(path.join(root, rel)), `${rel} is missing`);
});

Then('qualify-frozen-corrective-consumer: the init invalid scenario keeps its exit, provider, file and tree assertions', function () {
  const steps = scenarioSteps(FILES.setup, INIT_TITLE);
  for (const text of ['a Git project from fixture "notes"', 'the caller is signed in to ChatGPT', 'the fake ChatGPT server plays script "init-invalid-twice"', 'the caller runs "kogen init"',
    'the exit code is 4', 'the file ".kogen/project.yaml" does not exist', 'the working tree is unchanged']) need(steps, INIT_TITLE, text);
  assert.ok(!steps.some(step => step.text === 'stdout is:'), 'the init invalid scenario still compares all of stdout exactly');
  assert.ok(mentions(steps, 'provider/init_invalid: the model did not return a valid configuration; nothing was written'), 'the required primary diagnostic is no longer asserted');
});

Then('qualify-frozen-corrective-consumer: the init invalid stdout assertions accept the primary diagnostic with additive context', function () {
  const steps = scenarioSteps(FILES.setup, INIT_TITLE);
  const primary = 'provider/init_invalid: the model did not return a valid configuration; nothing was written';
  accepts(steps, { code: 4, stdout: `${primary}\n  check: project_config; reason: reply was not a valid configuration\n` });
  accepts(steps, { code: 4, stdout: `${primary}\n` });
});

Then('qualify-frozen-corrective-consumer: the init invalid stdout assertions reject output without the primary diagnostic', function () {
  const steps = scenarioSteps(FILES.setup, INIT_TITLE);
  rejects(steps, { code: 4, stdout: 'provider/login: not signed in\n  check: project_config; reason: x\n' }, 'another diagnostic');
  rejects(steps, { code: 4, stdout: '' }, 'empty stdout');
  rejects(steps, { code: 0, stdout: 'provider/init_invalid: the model did not return a valid configuration; nothing was written\n' }, 'exit code 0');
});

Then('qualify-frozen-corrective-consumer: the missing tool scenario keeps its exit, ruff absence and zero request assertions', function () {
  const steps = scenarioSteps(FILES.building, TOOL_TITLE);
  for (const text of ['the project config sets "commands.checks" to "[{name: lint, run: ruff check .}]"', 'the Intent "is-even" from fixture "is-even" is approved', 'the program "ruff" is not on PATH',
    'the caller runs "kogen intent build is-even"', 'the exit code is 3', 'the fake ChatGPT server received 0 requests']) need(steps, TOOL_TITLE, text);
  assert.ok(!steps.some(step => step.text === 'stdout is:'), 'the missing tool scenario still compares all of stdout exactly');
  assert.ok(!steps.some(step => /install.*ruff/i.test(step.text)), 'the scenario installs ruff');
  for (const needle of ['environment/tool_missing: ruff is not available', 'stopped in startup: tool_missing', 'evidence: ', 'index-at-start', 'kogen intent inspect {id8} --project']) {
    assert.ok(mentions(steps, needle), `the missing tool scenario no longer asserts: ${needle}`);
  }
});

Then('qualify-frozen-corrective-consumer: the missing tool stdout assertions accept additive check context and next-step lines', function () {
  const steps = scenarioSteps(FILES.building, TOOL_TITLE);
  accepts(steps, { code: 3, stdout: toolOutput(null) }, PROJECT);
  accepts(steps, { code: 3, stdout: toolOutput(lines => [lines[0], lines[2], lines[3]]) }, PROJECT);
});

Then('qualify-frozen-corrective-consumer: the missing tool stdout assertions reject a different tool or a missing stopped-startup or inspect line', function () {
  const steps = scenarioSteps(FILES.building, TOOL_TITLE);
  rejects(steps, { code: 3, stdout: toolOutput(lines => [lines[0].replace('ruff', 'pytest'), ...lines.slice(1)]) }, 'a different tool', PROJECT);
  rejects(steps, { code: 3, stdout: toolOutput(lines => lines.filter((line, index) => index !== 2)) }, 'output without the stopped-in-startup line', PROJECT);
  rejects(steps, { code: 3, stdout: toolOutput(lines => lines.filter((line, index) => index !== 3)) }, 'output without the inspect line', PROJECT);
  rejects(steps, { code: 3, stdout: toolOutput(lines => lines.map(line => line.replace('tool_missing; candidate', 'other; candidate'))) }, 'another startup reason', PROJECT);
});

Then('qualify-frozen-corrective-consumer: the Refine half is seeded by a successful Shape through a fake provider before the malicious fixture is installed', function () {
  const steps = scenarioSteps(FILES.lineup, MUTATION_TITLE);
  const at = text => steps.findIndex(step => step.text === text);
  const headMoved = steps.findIndex(step => step.text === 'stdout contains "candidate/head_moved"');
  const refineFake = at('a fake claude with script "lineup-refine-index" is installed as Kogen\'s Claude Code');
  const refine = steps.findIndex(step => step.text.startsWith('the caller refines "is-even" with its current baseline'));
  assert.ok(headMoved >= 0 && refineFake > headMoved && refine > refineFake, 'the head_moved assertion, the malicious Refine fixture and the Refine run are not in order');
  assert.ok(!steps.some(step => /is shaped/.test(step.text)), 'the scenario still seeds the Refine package with the manual "is shaped" fixture');
  const seed = steps.slice(headMoved + 1, refineFake);
  const shapeRun = seed.findIndex(step => step.text.startsWith('the caller runs "kogen intent shape is-even -"'));
  assert.ok(shapeRun >= 0, 'no kogen intent shape run seeds the Refine package before the malicious fixture');
  const exitAfter = seed.findIndex((step, index) => index > shapeRun && step.text === 'the exit code is 0');
  assert.ok(exitAfter > shapeRun, 'the seeding Shape run does not assert exit code 0');
  const provider = seed.slice(0, shapeRun).filter(step => /^a fake claude with script "(?!lineup-shape-head"|lineup-refine-index")/.test(step.text) || step.text === 'the fake ChatGPT server plays script "shape-ready-is-even"');
  assert.ok(provider.length > 0, 'the seeding Shape run uses no fake provider script that succeeds');
  assert.ok(!seed.some(step => /fake claude with script "lineup-(shape-head|refine-index)"/.test(step.text)), 'the seeding Shape uses a malicious fixture');
  for (const text of ['stdout contains "candidate/baseline_changed"', 'the file ".kogen/intents/is-even/intent.md" is unchanged']) {
    assert.ok(steps.findIndex(step => step.text === text) > refine, `the Refine half lost: ${text}`);
  }
  for (const text of ['stdout contains "candidate/head_moved"', 'no Intent named is-even exists', 'a fake claude with script "lineup-shape-head" is installed as Kogen\'s Claude Code']) need(steps, MUTATION_TITLE, text);
  assert.ok(steps.filter(step => step.text === 'the exit code is 1').length >= 2, 'both halves must still assert exit code 1');
});

Then('qualify-frozen-corrective-consumer: no scenario is removed or skipped and no protected or producer path is edited', function () {
  const expected = { [FILES.setup]: 21, [FILES.building]: 25, [FILES.lineup]: 22 };
  for (const [rel, count] of Object.entries(expected)) {
    const text = read(rel);
    assert.equal((text.match(/^\s*Scenario( Outline)?:/gm) || []).length, count, `${rel} changed its scenario count`);
    assert.ok(!/@(skip|wip|pending|manual|ignore)\b/.test(text), `${rel} has a skip tag`);
  }
  assert.ok(!fs.existsSync(path.join(root, 'AGENTS.md')), 'AGENTS.md was added');
  const changed = execFileSync('git', ['status', '--porcelain', '--untracked-files=all'], { cwd: root, encoding: 'utf8' }).split('\n').filter(Boolean).map(line => line.slice(3));
  const forbidden = changed.filter(file => /^(cli\/go\.mod|cli\/go\.sum|cli\/loop-pin\.json|cli\/third_party\/kogen-loop\/|\.kogen\/project\.yaml$|\.kogen\/models\.yaml$|AGENTS\.md$)/.test(file));
  assert.deepEqual(forbidden, [], `forbidden paths changed: ${forbidden.join(', ')}`);
});
