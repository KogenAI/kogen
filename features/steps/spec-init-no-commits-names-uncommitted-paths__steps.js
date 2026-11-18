const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { Given, Then } = require('@cucumber/cucumber');

const P = 'spec-init-no-commits-names-uncommitted-paths: ';
const FEATURE = 'spec/features/01-project-setup.feature';
const TITLE = 'Init in a repository whose files are not committed yet asks for the first commit';
const root = process.cwd();

const OLD = 'environment/no_commits: 1 file(s) are not committed yet; commit them first (git add -A && git commit -m "Initial commit"), then run kogen init';
const NEW = OLD.replace('yet;', 'yet (app.txt);');

function read(rel) { return fs.readFileSync(path.join(root, rel), 'utf8'); }

// Steps of the scenario with the title: [{ text, doc }] in order.
function scenarioSteps() {
  const lines = read(FEATURE).split(/\r?\n/);
  const start = lines.findIndex(line => line.trim() === `Scenario: ${TITLE}`);
  assert.ok(start >= 0, `${FEATURE} has no scenario "${TITLE}"`);
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
  assert.ok(steps.length > 0, `scenario "${TITLE}" has no steps`);
  return steps;
}

function need(steps, text) { assert.ok(steps.some(step => step.text === text), `scenario "${TITLE}" lost the step: ${text}`); }

// Independent replay of the exit code and stdout assertions of the scenario, with the handler semantics
// of test/acceptance/support/handlers.js: matches appends an optional line end to a trailing $.
function check(steps, result) {
  let pins = 0;
  for (const step of steps) {
    const code = step.text.match(/^the exit code is (\d+)$/);
    if (code) { assert.equal(result.code, Number(code[1]), `exit code ${result.code}`); continue; }
    if (step.text === 'stdout is:') {
      assert.equal(result.stdout.replace(/\r?\n$/, ''), step.doc, 'stdout differs from the exact block');
      pins++;
      continue;
    }
    const matches = step.text.match(/^stdout matches "([^"]*)"$/);
    if (matches) {
      assert.match(result.stdout, new RegExp(matches[1].replace(/\$$/, '(?:\\r?\\n)?$')));
      pins++;
      continue;
    }
    const contains = step.text.match(/^stdout contains "([^"]*)"$/);
    if (contains) { assert.ok(result.stdout.includes(contains[1]), `stdout did not contain ${contains[1]}`); pins++; continue; }
    if (/^stdout /.test(step.text)) throw new Error(`unsupported stdout step: ${step.text}`);
  }
  assert.ok(pins >= 1, 'the scenario pins no stdout text');
}
function attempt(steps, result) { try { check(steps, result); return null; } catch (error) { return error; } }
function accepts(steps, stdout, name) {
  const failure = attempt(steps, { code: 3, stdout });
  assert.equal(failure, null, `the assertions rejected ${name}: ${failure && failure.message}`);
}
function rejects(steps, result, name) {
  assert.ok(attempt(steps, result), `the assertions accepted ${name}`);
}

Given(`${P}the project setup feature is read`, function () {
  assert.ok(fs.existsSync(path.join(root, FEATURE)), `${FEATURE} is missing`);
});

Then(`${P}the scenario keeps its fixture, command and exit code 3`, function () {
  const steps = scenarioSteps();
  for (const text of ['a Git project from fixture "empty-repo"', 'the file "app.txt" is changed outside Kogen', 'the caller runs "kogen init"', 'the exit code is 3']) need(steps, text);
});

Then(`${P}the scenario no longer compares all of stdout exactly`, function () {
  const steps = scenarioSteps();
  assert.ok(!steps.some(step => step.text === 'stdout is:' || step.text === 'stdout is'), 'the scenario still compares all of stdout exactly');
});

Then(`${P}the stdout assertions accept the old text without the path`, function () {
  const steps = scenarioSteps();
  accepts(steps, `${OLD}\n`, 'the old text');
  accepts(steps, OLD, 'the old text without a final newline');
});

Then(`${P}the stdout assertions accept the new text naming the path`, function () {
  const steps = scenarioSteps();
  assert.equal(NEW, 'environment/no_commits: 1 file(s) are not committed yet (app.txt); commit them first (git add -A && git commit -m "Initial commit"), then run kogen init');
  accepts(steps, `${NEW}\n`, 'the new text');
  accepts(steps, NEW, 'the new text without a final newline');
});

Then(`${P}the stdout assertions reject every other message`, function () {
  const steps = scenarioSteps();
  const bad = {
    'another path': `${OLD.replace('yet;', 'yet (other.txt);')}\n`,
    'two paths': `${OLD.replace('yet;', 'yet (app.txt, other.txt);')}\n`,
    'empty parentheses': `${OLD.replace('yet;', 'yet ();')}\n`,
    'no space before the path': `${OLD.replace('yet;', 'yet(app.txt);')}\n`,
    'another count': `${NEW.replace('1 file(s)', '2 file(s)')}\n`,
    'the new text without the commit hint': `${NEW.replace('; commit them first (git add -A && git commit -m "Initial commit"), then run kogen init', '')}\n`,
    'the old text without the commit hint': `${OLD.replace('; commit them first (git add -A && git commit -m "Initial commit"), then run kogen init', '')}\n`,
    'the new text without the final clause': `${NEW.replace(', then run kogen init', '')}\n`,
    'another diagnostic code': `${NEW.replace('no_commits', 'other')}\n`,
    'a bare code': 'environment/no_commits\n',
    'an extra trailing line': `${NEW}\nextra\n`,
    'an extra leading line': `extra\n${NEW}\n`,
    'both texts': `${OLD}\n${NEW}\n`,
    'empty output': ''
  };
  for (const [name, stdout] of Object.entries(bad)) rejects(steps, { code: 3, stdout }, name);
  rejects(steps, { code: 0, stdout: `${NEW}\n` }, 'exit code 0');
});

Then(`${P}no scenario is removed or skipped and nothing else in the feature or the protected paths changes`, function () {
  const text = read(FEATURE);
  assert.equal((text.match(/^\s*Scenario( Outline)?:/gm) || []).length, 21, `${FEATURE} changed its scenario count`);
  assert.ok(!/@(skip|wip|pending|manual|ignore)\b/.test(text), `${FEATURE} has a skip tag`);
  assert.ok(/^ {2}@SET-2\n {2}Scenario: Init in a repository whose files are not committed yet/m.test(text), 'the scenario lost its @SET-2 tag');
  const status = execFileSync('git', ['status', '--porcelain', '--untracked-files=all'], { cwd: root, encoding: 'utf8' }).split('\n').filter(Boolean).map(line => line.slice(3));
  const allowed = [FEATURE, '.kogen/intents/spec-init-no-commits-names-uncommitted-paths/'];
  const stray = status.filter(file => !allowed.some(entry => file === entry || file.startsWith(entry)) && !/^features\/steps\/spec-init-no-commits-names-uncommitted-paths__/.test(file));
  assert.deepEqual(stray, [], `files other than the feature changed: ${stray.join(', ')}`);
  // Outside the scenario's stdout assertion the feature file is byte-identical to HEAD.
  const strip = source => source.replace(new RegExp(`(Scenario: ${TITLE}[\\s\\S]*?    Then the exit code is 3\\n)[\\s\\S]*?(\\n  @SET-10 @SET-13 @SHP-2 @VER-3\\n)`), '$1$2');
  const head = execFileSync('git', ['show', `HEAD:${FEATURE}`], { cwd: root, encoding: 'utf8' });
  assert.equal(strip(text), strip(head), `${FEATURE} changed outside the no_commits stdout assertion`);
});
