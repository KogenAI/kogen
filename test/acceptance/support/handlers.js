const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { execFileSync, spawnSync } = require('node:child_process');
const {
  ACCEPTANCE,
  NODE24,
  capture,
  findProgram,
  mkdirp,
  copyTree,
  commandToArgv,
} = require('./world');
const {
  FAKE_ACCESS_TOKEN,
  FAKE_REFRESH_TOKEN,
  ROTATED_REFRESH_TOKEN,
  DEFAULT_SCOPE,
  waitForAuthorizationUrl,
  getWithoutRedirect,
  flatten,
  intentFiles,
  counterFiles,
} = require('./fake-servers');

const topHelp = `Commands:\n  init       Prepare this Git repository for Kogen\n  intent     Shape, approve and build an Intent\n  provider   Sign in to ChatGPT and show the login\n  uninstall  Remove the installed kogen\n  version    Show the Kogen version\n  help       List commands\n\nRun kogen <command> to see its subcommands and options.\n`;
const intentHelp = `Usage: kogen intent <command> <slug> [arguments] [options]\n\nCommands:\n  shape <slug> <file|->     Shape an Intent from a request file (- reads stdin)\n  refine <slug> <sha256> <file|->  Correct existing files; require fresh approval\n  approve <slug> [<hash>]   Show the review card, or approve the Intent\n  build <slug>              Build, verify, review and commit the approved Intent\n  resume <build-id>         Continue a stopped Build in this checkout\n\nOptions:\n  --project <checkout>  Project checkout (default: current directory)\n  --by <name>           Approver (default: your Git identity)\n`;
const providerHelp = `Usage: kogen provider <command>\n\nCommands:\n  login chatgpt      Sign in with a ChatGPT account\n  list               Show whether Kogen is signed in\n\nLogins belong to this machine, never to a repo.\n`;

function plainPattern(source) {
  return source.slice(1, -1).replace(/\\([^A-Za-z0-9])/g, '$1');
}

function filePath(world, value) {
  value = value.replaceAll('{home}', world.home);
  if (value.includes('{build_id}')) value = value.replaceAll('{build_id}', resolveBuildId(world));
  if (path.isAbsolute(value)) return value;
  return path.resolve(world.project || world.workspace, value);
}

function projectFile(world, value) {
  return path.resolve(world.project || world.workspace, value);
}

function git(world, args, root = world.project) {
  assert.ok(root, 'no project has been created');
  const result = world.git(root, args);
  assert.equal(result.status, 0, `git ${args.join(' ')} failed: ${result.stderr || result.stdout}`);
  return result.stdout.trimEnd();
}

function statusPaths(world, root = world.project) {
  const output = world.git(root, ['status', '--porcelain=v1', '-z', '--untracked-files=all']);
  return output.stdout.split('\0').filter(Boolean).map(item => item.slice(3));
}

function safeRead(file) {
  try { return fs.readFileSync(file); } catch { return null; }
}

function walkFiles(dir, relative = '') {
  if (!fs.existsSync(dir)) return [];
  const results = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    const rel = path.join(relative, entry.name);
    if (entry.isSymbolicLink()) {
      results.push({ path: full, relative: rel, symlink: fs.readlinkSync(full) });
    } else if (entry.isDirectory()) {
      results.push(...walkFiles(full, rel));
    } else if (entry.isFile()) {
      results.push({ path: full, relative: rel, digest: crypto.createHash('sha256').update(fs.readFileSync(full)).digest('hex') });
    }
  }
  return results;
}

function captureFolder(world, folder) {
  const root = filePath(world, folder);
  const map = new Map();
  for (const entry of walkFiles(root)) map.set(entry.relative, entry.symlink ? `link:${entry.symlink}` : entry.digest);
  return { root, map };
}

function configText() {
  return [
    'version: 1',
    'commands:',
    '  setup: []',
    "  fix: ['true']",
    '  checks: [{name: test, run: "python3 -m unittest"}]',
    '  acceptance:',
    '    run: \'node_modules/.bin/cucumber-js --strict --require "features/steps/*.js" --format message:$KOGEN_ACCEPTANCE_REPORT $KOGEN_ACCEPTANCE_FEATURES\'',
    '    steps_dir: features/steps',
    'protect: [.style.cfg]',
    'models:',
    '  shape:  {model: gpt-6.1-sol, effort: high}',
    '  build:  {model: gpt-6.1-sol, effort: medium}',
    '  review: {model: gpt-6.1-sol, effort: high}',
    '',
  ].join('\n');
}

function setConfigKey(world, key, value) {
  const file = projectFile(world, '.kogen/project.yaml');
  let content = fs.readFileSync(file, 'utf8');
  const lineMap = {
    'commands.setup': /^  setup:.*$/m,
    'commands.fix': /^  fix:.*$/m,
    'commands.checks': /^  checks:.*$/m,
    'commands.acceptance.run': /^    run:.*$/m,
    'commands.acceptance.steps_dir': /^    steps_dir:.*$/m,
    protect: /^protect:.*$/m,
  };
  const line = lineMap[key];
  assert.ok(line, `unsupported config setting in fixture: ${key}`);
  const formatted = value === 'null' ? 'null' : value;
  if (key === 'commands.acceptance.run' && formatted !== 'null' && !formatted.startsWith("'") && !formatted.startsWith('"')) {
    content = content.replace(line, `    run: '${formatted.replaceAll("'", "''")}'`);
  } else {
    content = content.replace(line, `${key === 'protect' ? 'protect' : key.endsWith('.run') ? '    run' : key.endsWith('.steps_dir') ? '    steps_dir' : `  ${key.split('.').at(-1)}`}: ${formatted}`);
  }
  fs.writeFileSync(file, content);
  git(world, ['add', '--', '.kogen/project.yaml']);
  const commit = world.git(world.project, ['commit', '-q', '-m', 'Acceptance config change']);
  assert.equal(commit.status, 0, commit.stderr || commit.stdout);
}

function installAcceptanceRunner(world, mode) {
  const modules = projectFile(world, 'node_modules');
  fs.rmSync(modules, { recursive: true, force: true });
  mkdirp(path.join(modules, '.bin'));
  fs.symlinkSync(path.join(ACCEPTANCE, 'node_modules/@cucumber'), path.join(modules, '@cucumber'), 'dir');
  const runner = path.join(modules, '.bin/cucumber-js');
  const realCucumber = path.join(ACCEPTANCE, 'node_modules/.bin/cucumber-js');
  const fixtureRunner = path.join(ACCEPTANCE, 'fixtures/runners/run.js');
  const source = `#!/usr/bin/env node\nconst fs = require('node:fs');
const http = require('node:http');\nconst { spawnSync } = require('node:child_process');\nconst mode = ${JSON.stringify(mode)};\nif (mode === 'record') {\n  fs.mkdirSync('.kogen/local', { recursive: true });\n  fs.writeFileSync('.kogen/local/acceptance-env.json', JSON.stringify({ features: process.env.KOGEN_ACCEPTANCE_FEATURES, report: process.env.KOGEN_ACCEPTANCE_REPORT }));\n}\nconst script = mode === 'record' ? ${JSON.stringify(realCucumber)} : ${JSON.stringify(fixtureRunner)};\nconst args = mode === 'record' ? process.argv.slice(2) : [script, mode, ...process.argv.slice(2)];\nconst result = spawnSync(process.execPath, mode === 'record' ? [script, ...args] : args, { stdio: 'inherit' });\nprocess.exit(result.status === null ? 1 : result.status);\n`;
  fs.writeFileSync(runner, source, { mode: 0o755 });
  fs.chmodSync(runner, 0o755);
}

function currentBaselineFiles(world, slug) {
  const dir = projectFile(world, `.kogen/intents/${slug}`);
  const files = new Set();
  for (const entry of walkFiles(dir)) {
    if (!entry.symlink) files.add(path.relative(world.project, entry.path).split(path.sep).join('/'));
  }
  for (const file of acceptanceFiles(world, slug)) files.add(file);
  files.add('.kogen/project.yaml');
  const cfg = fs.readFileSync(projectFile(world, '.kogen/project.yaml'), 'utf8');
  const protect = cfg.match(/^protect:\s*\[(.*?)\]\s*$/m);
  if (protect) for (const item of protect[1].split(',').map(part => part.trim()).filter(Boolean)) files.add(item.replace(/^['"]|['"]$/g, ''));
  return [...files].filter(file => fs.existsSync(projectFile(world, file))).sort();
}

function acceptanceFiles(world, slug) {
  const intent = fs.readFileSync(projectFile(world, `.kogen/intents/${slug}/intent.md`), 'utf8');
  const lines = intent.split(/\r?\n/);
  const start = lines.indexOf('Acceptance:');
  if (start < 0) return [];
  const files = [];
  for (const line of lines.slice(start + 1)) {
    if (!line.startsWith('- ')) break;
    files.push(line.slice(2).trim());
  }
  return files;
}

function baselineHash(world, slug) {
  const records = currentBaselineFiles(world, slug).map(file => {
    const digest = crypto.createHash('sha256').update(fs.readFileSync(projectFile(world, file))).digest('hex');
    return `${file}\0${digest}\n`;
  }).join('');
  return crypto.createHash('sha256').update(records).digest('hex');
}

function runDirectoryNames(world) {
  const root = path.join(world.buildProject || world.project || world.workspace, '.kogen/local/runs');
  if (!fs.existsSync(root)) return [];
  return fs.readdirSync(root).filter(name => /^[0-9a-f]{8}$/.test(name));
}

function resolveBuildId(world) {
  const root = path.join(world.buildProject || world.project || world.workspace, '.kogen/local/runs');
  const ids = runDirectoryNames(world);
  if (world.lastBuildId) {
    assert.ok(ids.includes(world.lastBuildId), `stdout Build id ${world.lastBuildId} has no matching run folder`);
    return world.lastBuildId;
  }
  assert.ok(ids.length, 'stdout had no Build id and no run folder exists');
  return ids.sort((a, b) => fs.statSync(path.join(root, b)).mtimeMs - fs.statSync(path.join(root, a)).mtimeMs)[0];
}

function rememberBaseline(world, slug) {
  if (!world.fileBaselines) world.fileBaselines = new Map();
  for (const file of currentBaselineFiles(world, slug)) world.fileBaselines.set(file, fs.readFileSync(projectFile(world, file)));
}

function initTemplate() {
  return [
    'version: 1',
    'commands:',
    '  setup: []          # run before readiness dry runs and before each Build',
    '  fix: []            # deterministic fixers, run once after each builder round',
    '  checks: []         # project checks, e.g. {name: test, run: "mix test"}',
    '  acceptance:',
    '    run: null        # the acceptance command (VER-3)',
    '    steps_dir: null  # where shaping writes step-definition files',
    'protect: []          # check configuration the Build must not change, e.g. .credo.exs',
    'models:',
    '  shape:',
    '    model: gpt-6.1-sol',
    '    effort: high',
    '  build:',
    '    model: gpt-6.1-sol',
    '    effort: medium',
    '  review:',
    '    model: gpt-6.1-sol',
    '    effort: high',
    '',
  ].join('\n');
}

function shellQuote(value) {
  return `'${String(value).replaceAll("'", "'\\''")}'`;
}

function installHook(world, name, contents) {
  const hooks = git(world, ['rev-parse', '--git-path', 'hooks']);
  const dir = path.isAbsolute(hooks) ? hooks : path.resolve(world.project, hooks);
  mkdirp(dir);
  const hook = path.join(dir, name);
  fs.writeFileSync(hook, contents, { mode: 0o755 });
  fs.chmodSync(hook, 0o755);
  return hook;
}

function configureSigning(world, missing) {
  const key = path.join(world.workspace, missing ? 'missing-signing-key' : 'test-signing-key');
  if (!missing) {
    const sshKeygen = findProgram('ssh-keygen');
    assert.ok(sshKeygen, 'ssh-keygen is required for the test signing key');
    const generated = spawnSync(sshKeygen, ['-q', '-t', 'ed25519', '-N', '', '-f', key], {
      encoding: 'utf8', env: world.env(),
    });
    assert.equal(generated.status, 0, generated.stderr || generated.stdout);
    const [keyType, keyData] = fs.readFileSync(`${key}.pub`, 'utf8').trim().split(/\s+/);
    world.allowedSignersFile = path.join(world.workspace, 'allowed_signers');
    fs.writeFileSync(world.allowedSignersFile, `kogen@example.invalid namespaces="git" ${keyType} ${keyData}\n`, { mode: 0o600 });
  }
  for (const [name, value] of [
    ['gpg.format', 'ssh'],
    ['user.signingkey', key],
    ['commit.gpgsign', 'true'],
  ]) {
    const result = world.git(world.project, ['config', name, value]);
    assert.equal(result.status, 0, result.stderr || result.stdout);
  }
}

async function waitForServerRequest(world, predicate, timeoutMs = 30000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const found = world.server.requests.find(predicate);
    if (found) return found;
    await new Promise(resolve => setTimeout(resolve, 25));
  }
  assert.fail('the fake ChatGPT server did not receive the expected request');
}

async function reachPause(world, point) {
  world.trackCoreGroups();
  if (point === 'git commit running') {
    assert.ok(world.preCommitMarker, 'the sleeping pre-commit hook is not configured');
    const start = Date.now();
    while (Date.now() - start < 30000) {
      if (fs.existsSync(world.preCommitMarker)) {
        const [pid, ppid, pgid] = fs.readFileSync(world.preCommitMarker, 'utf8').trim().split(/\s+/).map(Number);
        const group = world.trackProcessGroup(pid, ppid, pgid);
        assert.ok(group, 'the pre-commit hook reached its pause but its Build process group was not recorded');
        return { pid, ppid, group };
      }
      await new Promise(resolve => setTimeout(resolve, 25));
    }
    assert.fail('git commit did not start');
  }
  const reached = await world.server.waitReached(point, 30000);
  if (point === 'tool command running') {
    const command = reached.command || '';
    const group = await world.waitForCommandGroup(command);
    return { command, group };
  }
  return reached;
}

async function findCorePid(world) {
  const record = world.currentProcess;
  assert.ok(record?.child?.pid, 'no Kogen command is running');
  const start = Date.now();
  while (Date.now() - start < 10000) {
    world.trackCoreGroups();
    if (fs.existsSync(world.corePidFile)) {
      const pid = Number(fs.readFileSync(world.corePidFile, 'utf8').trim().split(/\s+/).at(-1));
      if (Number.isInteger(pid) && pid > 1) {
        try { process.kill(pid, 0); return pid; }
        catch (error) { if (error.code === 'EPERM') return pid; }
      }
    }
    await new Promise(resolve => setTimeout(resolve, 25));
  }
  assert.fail('Kogen core process was not found');
}

function fileAssertions(world, label, args, attachment, actual) {
  const value = args[0];
  const target = filePath(world, value);
  if (label.startsWith('the folder ')) {
    if (label.endsWith(' does not exist')) assert.equal(fs.existsSync(target), false, `${value} exists`);
    else assert.equal(fs.existsSync(target) && fs.statSync(target).isDirectory(), true, `${value} is not a folder`);
    return;
  }
  if (label.includes(' is changed outside Kogen')) {
    mkdirp(path.dirname(target));
    const extension = path.extname(target).toLowerCase();
    const line = ['.yaml', '.yml', '.py', '.sh', '.feature'].includes(extension)
      ? '# changed'
      : ['.js', '.mjs', '.cjs', '.ts'].includes(extension)
        ? '// changed'
        : 'changed';
    const separator = fs.existsSync(target) && fs.statSync(target).size ? '\n' : '';
    fs.appendFileSync(target, `${separator}${line}\n`);
    return;
  }
  if (label.includes(' is created and staged')) {
    mkdirp(path.dirname(target));
    fs.writeFileSync(target, 'created and staged by the caller\n');
    const relative = path.relative(world.project, target).split(path.sep).join('/');
    git(world, ['add', '--', relative]);
    return;
  }
  if (label.includes(' is unchanged')) {
    const relative = path.relative(world.project, target).split(path.sep).join('/');
    const baseline = world.fileBaselines?.get(relative);
    // The committed bytes as they are; git()'s output is trimmed for messages, not for content.
    const committed = () => {
      const shown = world.git(world.project, ['show', `HEAD:${relative}`]);
      assert.equal(shown.status, 0, `${value} is not in HEAD`);
      return Buffer.from(shown.stdout);
    };
    const original = baseline || committed();
    assert.ok(fs.existsSync(target), `${value} does not exist`);
    assert.ok(fs.readFileSync(target).equals(original), `${value} changed`);
    return;
  }
  if (label.includes(' has mode ')) {
    const expected = Number.parseInt(args[1], 8);
    assert.equal(fs.statSync(target).mode & 0o777, expected);
    return;
  }
  if (label.endsWith(' lines?')) {
    const lines = fs.readFileSync(target, 'utf8').split('\n').filter(line => line !== '');
    assert.equal(lines.length, Number(args[1]), `${value} has ${lines.length} lines`);
    return;
  }
  if (label.includes(' is a symlink into ')) {
    const linkTarget = fs.readlinkSync(target);
    const resolved = path.resolve(path.dirname(target), linkTarget);
    assert.ok(pathInside(filePath(world, args[1]), resolved), `${value} points to ${resolved}`);
    return;
  }
  if (label.includes(' does not exist')) {
    assert.equal(fs.existsSync(target), false, `${value} exists`);
    return;
  }
  if (label.includes(' exists')) {
    assert.equal(fs.existsSync(target), true, `${value} does not exist`);
    return;
  }
  if (label.includes(' contains ')) {
    assertContainsTemplate(world, fs.readFileSync(target, 'utf8'), args[1], value);
    return;
  }
  if (label.includes(' does not contain ')) {
    assert.ok(!fs.readFileSync(target, 'utf8').includes(args[1]), `${value} contains ${args[1]}`);
    return;
  }
  assert.fail(`file assertion is not implemented: ${label}`);
}

function requestAssertions(world, label, args) {
  const ordinal = Number(args[0]);
  const request = world.server.requests[ordinal - 1];
  assert.ok(request, `no request ${ordinal} was received`);
  const actualText = request.text;
  if (label.includes(' has index-first source navigation for ')) {
    const line = actualText.split('\n').find(line => line.startsWith('Context index: '));
    assert.ok(line, 'missing source index');
    const index = JSON.parse(line.slice('Context index: '.length));
    const entry = index.entries.find(entry => entry.path === args[1]);
    assert.ok(entry && entry.sha256 && entry.bytes && entry.signatures.length);
    assert.equal(index.root, world.project);
    assert.ok(index.revision.head && index.revision.tree);
    assert.equal(entry.source, undefined);
    assert.equal(entry.revision, undefined);
    assert.ok(!actualText.includes('Excerpt: '));
    assert.ok(!actualText.includes(fs.readFileSync(projectFile(world, args[1]), 'utf8')));
    return;
  }
  if (label.includes(' contains the text of the file ')) {
    const text = fs.readFileSync(projectFile(world, args[1]), 'utf8');
    assert.ok(actualText.includes(text), `request ${ordinal} did not contain ${args[1]}`);
    return;
  }
  if (label.includes(' offers exactly the tools ')) {
    assert.equal(request.tools.join(', '), args[1]);
    return;
  }
  if (label.includes(' uses model ')) {
    assert.equal(request.body.model, args[1]);
    assert.equal(request.body.reasoning?.effort, args[2]);
    return;
  }
  if (label.includes(' contains ')) {
    assert.ok(actualText.includes(args[1]), `request ${ordinal} did not contain ${args[1]}`);
    return;
  }
  assert.fail(`request assertion is not implemented: ${label}`);
}

function reviewAssertions(world, label, args) {
  const matches = world.server.requests.filter(request => request.kind === 'review');
  const reviewOrdinal = label.match(/review request (\d+)/)?.[1];
  const request = matches[Number(reviewOrdinal || 1) - 1];
  assert.ok(request, 'no review request was received');
  if (label.includes('used read_file on ')) {
    const call = world.server.responseItems.find(item => item.kind === 'review' && item.requestOrder >= request.order && item.name === 'read_file' && item.args.path === args[0]);
    assert.ok(call, `reviewer did not call read_file on ${args[0]}`);
    const fixturePath = path.join(ACCEPTANCE, 'fixtures/projects', world.projectFixture || '', args[0]);
    assert.ok(fs.existsSync(fixturePath), `no project fixture content is available for ${args[0]}`);
    const fileText = fs.readFileSync(fixturePath, 'utf8');
    const nextReviewRequest = world.server.requests.find(item => item.kind === 'review' && item.order > call.requestOrder);
    assert.ok(nextReviewRequest, 'no review request followed the read_file call');
    const returned = (nextReviewRequest.body.input || []).find(item => item.type === 'function_call_output' && item.call_id === call.callId);
    assert.ok(returned, `the next review request did not carry a function_call_output for read_file call ${call.callId}`);
    const numberedLinesRemoved = String(returned.output).split(/\r?\n/).map(line => line.replace(/^\d+\t/, '')).join('\n');
    assert.ok(numberedLinesRemoved.trimEnd().includes(fileText.trimEnd()), `the read_file result for ${args[0]} did not contain its fixture text`);
    return;
  }
  if (label.includes(' contains the diff of ')) {
    const start = world.buildStartHead;
    const rel = args[0];
    assert.ok(start, 'Build start HEAD was not recorded');
    const diff = git(world, ['diff', start, 'HEAD', '--', rel]);
    assert.ok(diff && request.text.includes(diff), `review request did not contain the diff of ${rel}`);
    return;
  }
  if (label.includes(' contains the full text of the committed ')) {
    const content = fs.readFileSync(projectFile(world, args[0]), 'utf8');
    assert.ok(request.text.includes(content), `review request did not contain the full candidate ${args[0]}`);
    return;
  }
  if (label.includes(' contains the text of the file ')) {
    const content = fs.readFileSync(projectFile(world, args[0]), 'utf8');
    assert.ok(request.text.includes(content), `review request did not contain ${args[0]}`);
    return;
  }
  if (label.includes(' offers exactly the tools ')) {
    assert.equal(request.tools.join(', '), args[0]);
    return;
  }
  if (label.includes(' uses model ')) {
    assert.equal(request.body.model, args[0]);
    assert.equal(request.body.reasoning?.effort, args[1]);
    return;
  }
  if (label.includes(' does not contain the builder')) {
    for (const item of request.body.input || []) {
      assert.notEqual(item.type, 'function_call', 'review input includes a function_call');
      assert.notEqual(item.type, 'function_call_output', 'review input includes a function_call_output');
      assert.notEqual(item.role, 'assistant', 'review input includes an assistant message');
    }
    for (const response of world.server.responses.filter(item => item.kind === 'build')) {
      for (const item of response.items.filter(value => value.type === 'message')) {
        for (const content of item.content || []) {
          if (content.type === 'output_text' && content.text) assert.ok(!request.text.includes(content.text), 'review input includes builder message text');
        }
      }
    }
    return;
  }
  if (label.includes(' contains ')) {
    assert.ok(request.text.includes(args[0]), `review request did not contain ${args[0]}`);
    return;
  }
  assert.fail(`review assertion is not implemented: ${label}`);
}

function inputItemsAddedAfter(previous, current) {
  const before = previous?.body.input || [];
  const after = current.body.input || [];
  const counts = new Map();
  for (const item of before) {
    const key = JSON.stringify(item);
    counts.set(key, (counts.get(key) || 0) + 1);
  }
  const added = [];
  for (const item of after) {
    const key = JSON.stringify(item);
    const count = counts.get(key) || 0;
    if (count) counts.set(key, count - 1);
    else added.push(item);
  }
  return added;
}

function afterRequestAssertions(world, label, args) {
  if (label.includes('after verification pass ')) {
    const pass = Number(args[0]);
    const wanted = args[1];
    const builds = world.server.requests.filter(request => request.kind === 'build');
    const marker = `Verification pass ${pass} is not green.`;
    const candidates = builds.slice(1).map((request, index) => ({ request, added: inputItemsAddedAfter(builds[index], request) }));
    const request = candidates.find(candidate => flatten(candidate.added).some(text => text.split(/\r?\n/).some(line => line.trim().startsWith(marker))));
    assert.ok(request, `no new builder input contained the exact feedback marker ${marker}`);
    const newText = flatten(request.added);
    assert.ok(newText.some(text => text.includes(wanted)), `builder input added after pass ${pass} did not contain ${JSON.stringify(wanted)}; feedback item: ${JSON.stringify(newText.find(text => text.includes(marker)) || '')}`);
    return;
  }
  assert.fail(`request feedback assertion is not implemented: ${label}`);
}

function toolResultAssertions(world, label, args) {
  let result;
  if (label.includes('for the first shell call')) {
    result = world.server.toolResults.find(item => item.name === 'shell' && item.kind === 'build');
    assert.ok(result, 'no shell result was received');
    assert.ok(result.output.includes(args[0]), `shell result did not contain ${args[0]}`);
    return;
  }
  const query = args[0];
  result = findServerToolResult(world, query);
  assert.ok(result, `no tool result was received for ${query}`);
  const output = String(result.output ?? '');
  if (label.includes(' contains ')) assert.ok(output.includes(args[1]), `tool result did not contain ${args[1]}`);
  else if (label.includes(' starts with ')) assert.ok(output.startsWith(args[1]), `tool result did not start with ${args[1]}`);
  else if (label.includes(' ends with ')) assert.ok(output.trimEnd().endsWith(args[1]), `tool result did not end with ${args[1]}`);
  else if (label.includes(' is at most ')) assert.ok(Buffer.byteLength(output) <= Number(args[1]), `tool result was ${Buffer.byteLength(output)} bytes`);
  else if (label.includes(' is ')) assert.equal(output, args[1]);
  else assert.fail(`tool result assertion is not implemented: ${label}`);
}

function runLogAssertions(world, label, args) {
  const events = runEvents(world);
  if (label.includes('shows fix-')) {
    const passIndex = events.findIndex(event => event.event === 'pass' && event.pass === Number(args[1]));
    const fixes = events.filter((event, index) => event.event === 'command' && event.name === `fix-${args[0]}` && index < passIndex);
    assert.ok(passIndex >= 0, `run log did not show verification pass ${args[1]}`);
    assert.equal(fixes.length, 1);
    return;
  }
  if (label.includes('shows verification pass ')) {
    const passIndex = events.findIndex(event => event.event === 'pass' && event.pass === Number(args[0]));
    const reviewIndex = events.findIndex(event => event.event === 'review' && event.review === Number(args[1]));
    assert.ok(passIndex >= 0 && passIndex < reviewIndex);
    return;
  }
  if (label.includes('shows the command ')) {
    assert.ok(events.some(event => event.event === 'command' && event.command === args[0]), `run log did not show ${args[0]}`);
    return;
  }
  if (label.includes('shows Quint ran with the Node')) {
    const nodeFile = path.join(world.prefix, 'lib/kogen/node-path');
    const expected = fs.readFileSync(nodeFile, 'utf8').trim();
    const model = events.find(event => event.event === 'command' && event.name === 'model');
    assert.ok(model, 'run log did not record the Quint command');
    assert.equal(model.node, expected);
    return;
  }
  assert.fail(`run log assertion is not implemented: ${label}`);
}

function outputPattern(world, expected) {
  let out = '^';
  let at = 0;
  const token = /\{(sha8|sha256|id8|build_id|n|dur|model|effort|ident|url|home|path_node|abs:([^}]+))\}/g;
  const tokenGroups = [];
  for (const match of expected.matchAll(token)) {
    out += escapeRegex(expected.slice(at, match.index));
    const name = match[1];
    if (name === 'sha8' || name === 'id8' || name === 'sha256') {
      const group = `placeholder_${tokenGroups.length}`;
      const size = name === 'sha256' ? 64 : 8;
      out += `(?<${group}>[0-9a-f]{${size}})`;
      tokenGroups.push({ group, name, offset: match.index });
    } else if (name === 'build_id') out += escapeRegex(resolveBuildId(world));
    else if (name === 'n') out += '\\d+';
    else if (name === 'dur') out += '(?:\\d+h)?(?:\\d+m)?\\d+s';
    else if (name === 'model') out += escapeRegex(configuredModel(world, expected, match.index).model);
    else if (name === 'effort') out += escapeRegex(configuredModel(world, expected, match.index).effort);
    else if (name === 'ident') out += 'Kogen Acceptance <kogen@example\\.invalid>';
    else if (name === 'url') out += 'https?://[^\\s]+';
    else if (name === 'home') out += escapeRegex(world.home);
    else if (name === 'path_node') out += escapeRegex(world.nodePath || '');
    else if (name.startsWith('abs:')) {
      const rel = match[2] === '.' ? '.' : match[2];
      out += escapeRegex(path.resolve(world.project || world.workspace, rel));
    }
    at = match.index + match[0].length;
  }
  out += escapeRegex(expected.slice(at)) + '$';
  const regexp = new RegExp(out, 's');
  regexp.tokenGroups = tokenGroups;
  return regexp;
}

function configuredModel(world, expected, tokenIndex) {
  const line = expected.slice(0, tokenIndex).split(/\r?\n/).at(-1).trim();
  const role = line.split(/\s+/)[0];
  assert.ok(role, `could not resolve model role from line: ${line}`);
  const config = fs.readFileSync(projectFile(world, '.kogen/project.yaml'), 'utf8');
  const match = config.match(new RegExp(`^\\s+${escapeRegex(role)}:\\s*\\{model:\\s*([^,}]+),\\s*effort:\\s*([^}]+)\\}`, 'm'));
  assert.ok(match, `models.${role} is missing from .kogen/project.yaml`);
  return { model: match[1].trim(), effort: match[2].trim() };
}

function verifyOutputTokens(world, expected, match, regexp) {
  const slug = world.intentSlug || 'is-even';
  for (const token of regexp.tokenGroups) {
    const value = match.groups[token.group];
    const line = expected.slice(0, token.offset).split(/\r?\n/).at(-1);
    if (token.name === 'sha256') {
      assert.equal(value, baselineHash(world, slug), `review card SHA-256 differs from the acceptance baseline for ${slug}`);
      world.reviewCardHashes.set(slug, value);
    } else if (token.name === 'sha8') {
      if (/\b(?:approved|approve)\b/.test(line)) {
        const cardHash = world.reviewCardHashes.get(slug);
        assert.ok(cardHash, `no review card SHA-256 was captured for ${slug}`);
        assert.equal(value, cardHash.slice(0, 8), 'approval hash prefix differs from the review card');
      } else if (/\b(?:Commit:|landed\s)/.test(line)) {
        const resolved = world.git(world.project, ['rev-parse', '--verify', `${value}^{commit}`]);
        assert.equal(resolved.status, 0, `${value} does not resolve to a commit`);
        const head = world.head(world.project);
        assert.equal(resolved.stdout.trim(), head, `${value} does not identify HEAD`);
        assert.ok(head.startsWith(value), `${value} does not prefix HEAD`);
      } else {
        assert.fail(`cannot determine what {sha8} refers to in: ${line}`);
      }
    } else if (token.name === 'id8') {
      assert.equal(value, world.lastBuildId, 'Build id in stdout differs from the id parsed from stdout');
      assert.ok(runDirectoryNames(world).includes(value), `Build ${value} has no matching run folder`);
    }
  }
}

function escapeRegex(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function assertContainsTemplate(world, actual, expected, label) {
  const regex = outputPattern(world, expected);
  const haystack = String(actual);
  const sub = new RegExp(regex.source.replace(/^\^|\$$/g, ''), 's');
  const match = haystack.match(sub);
  assert.ok(match, `${label} did not contain expected text\nExpected: ${expected}\nActual: ${haystack}`);
  verifyOutputTokens(world, expected, match, regex);
}

function exactTemplate(world, actual, expected, label) {
  const normalized = String(expected).replace(/\r\n/g, '\n');
  const withNewline = normalized.endsWith('\n') ? normalized : `${normalized}\n`;
  const regex = outputPattern(world, withNewline);
  const match = String(actual).match(regex);
  assert.ok(match, `${label} was not exact\nExpected: ${normalized}\nActual: ${actual}`);
  verifyOutputTokens(world, withNewline, match, regex);
}

function lastResult(world) {
  assert.ok(world.lastResult, 'no command result is available');
  return world.lastResult;
}

function parseTable(table) {
  if (!table) return [];
  if (typeof table.raw === 'function') return table.raw();
  if (Array.isArray(table)) return table;
  return [];
}

function latestRunDir(world) {
  const root = path.join(world.buildProject || world.project || world.workspace, '.kogen/local/runs');
  const dirs = runDirectoryNames(world);
  if (!dirs.length) return null;
  const id = resolveBuildId(world);
  return path.join(root, id);
}

function runEvents(world) {
  const dir = latestRunDir(world);
  const log = dir && path.join(dir, 'log.jsonl');
  if (!log || !fs.existsSync(log)) return [];
  return fs.readFileSync(log, 'utf8').split(/\r?\n/).filter(Boolean).map(line => JSON.parse(line));
}

function toolArg(item) {
  const args = item.args || {};
  if (item.name === 'shell' || item.name === 'probe') return normalizeCommand(args.command || '');
  if (item.name === 'read_file' || item.name === 'write_file') return args.path || '';
  return item.name;
}

function normalizeCommand(command) {
  return command.replace(/'([^']*)'/g, '$1').replace(/"([^"]*)"/g, '$1').trim();
}

function findServerToolResult(world, query) {
  const [name, ...rest] = query.split(' ');
  const target = rest.join(' ');
  return world.server.toolResults.find(result => {
    if (result.name !== name) return false;
    return !target || toolArg(result) === normalizeCommand(target);
  });
}

function saveBuildStart(world, raw, cwd) {
  if (/^kogen\s+intent\s+build\b/.test(raw)) {
    const root = world.projectForCommand(raw, cwd);
    world.buildStartHead = world.head(root);
    world.buildProject = root;
    world.lastBuildId = null;
  }
}

async function runProduct(world, command, options = {}) {
  const cwd = options.cwd || world.project || world.archiveDir || world.workspace;
  const shape = command.match(/^kogen\s+intent\s+shape\s+(\S+)/);
  if (shape) world.intentSlug = shape[1];
  saveBuildStart(world, command, cwd);
  if (command.includes('install.sh --prefix') || command.startsWith('sh install.sh --prefix')) world.homeBeforeInstall = captureFolder(world, world.home);
  const record = await world.invoke(command, { ...options, cwd, env: { ...(world.extraEnv || {}), ...(options.env || {}) } });
  return record;
}

// STEPS.md "Initialized projects": the template state kogen init leaves in an empty repository,
// without running init itself (chapter 01's scenarios run it).
async function initProject(world, configure) {
  const configFile = projectFile(world, '.kogen/project.yaml');
  mkdirp(path.dirname(configFile));
  fs.writeFileSync(configFile, initTemplate());
  const ignore = projectFile(world, '.gitignore');
  let text = fs.existsSync(ignore) ? fs.readFileSync(ignore, 'utf8') : '';
  if (!text.split(/\r?\n/).includes('.kogen/local/')) text += `${text && !text.endsWith('\n') ? '\n' : ''}.kogen/local/\n`;
  fs.writeFileSync(ignore, text);
  git(world, ['add', '--', '.kogen/project.yaml', '.gitignore']);
  const initCommit = world.git(world.project, ['commit', '-q', '-m', 'Add Kogen configuration']);
  assert.equal(initCommit.status, 0, initCommit.stderr || initCommit.stdout);
  if (configure) {
    // Only the hand-configured fixture uses the harness's project-local runner. A real init
    // must see the project's original dependency state and select its own bridge.
    const modules = projectFile(world, 'node_modules');
    fs.rmSync(modules, { recursive: true, force: true });
    fs.symlinkSync(path.join(ACCEPTANCE, 'node_modules'), modules, 'dir');
    fs.writeFileSync(projectFile(world, '.kogen/project.yaml'), configText());
    git(world, ['add', '--', '.kogen/project.yaml']);
    const commit = world.git(world.project, ['commit', '-q', '-m', 'Configure acceptance checks']);
    assert.equal(commit.status, 0, commit.stderr || commit.stdout);
  }
}

function copyIntent(world, slug, fixture) {
  const source = path.join(ACCEPTANCE, 'fixtures/intents', fixture);
  const fallback = path.join(ACCEPTANCE, 'fixtures/intents/is-even');
  const sourceFile = name => fs.existsSync(path.join(source, name)) ? path.join(source, name) : path.join(fallback, name);
  const files = ['intent.md', 'acceptance.feature'];
  if (fixture === 'counter-with-model') files.push('model.qnt');
  for (const name of files) {
    const destinationName = name === 'model.qnt' ? 'model.qnt' : name;
    const destination = projectFile(world, `.kogen/intents/${slug}/${destinationName}`);
    mkdirp(path.dirname(destination));
    fs.copyFileSync(sourceFile(name), destination);
  }
  if (fixture === 'counter-with-model') {
    const destination = projectFile(world, 'features/steps/counter_steps.js');
    mkdirp(path.dirname(destination));
    fs.copyFileSync(path.join(source, 'counter_steps.js'), destination);
  } else {
    const destination = projectFile(world, 'features/steps/is_even_steps.js');
    mkdirp(path.dirname(destination));
    fs.copyFileSync(sourceFile('is_even_steps.js'), destination);
  }
  world.intentSlug = slug;
  rememberBaseline(world, slug);
}

async function approveThroughKogen(world, slug) {
  const card = await runProduct(world, `kogen intent approve ${slug}`, { cwd: world.project });
  assert.equal(card.code, 5, card.stdout + card.stderr);
  const hash = card.stdout.match(/^SHA-256: ([0-9a-f]{64})$/m)?.[1];
  assert.ok(hash, 'approval card did not include a SHA-256 hash');
  assert.equal(hash, baselineHash(world, slug), `review card SHA-256 differs from the acceptance baseline for ${slug}`);
  world.reviewCardHashes.set(slug, hash);
  const approved = await runProduct(world, `kogen intent approve ${slug} ${hash}`, { cwd: world.project });
  assert.equal(approved.code, 0, approved.stdout + approved.stderr);
  rememberBaseline(world, slug);
  return hash;
}

function intentSourceFile(world, slug, relative) {
  return projectFile(world, `.kogen/intents/${slug}/${relative}`);
}

function currentCredential(world) {
  const file = path.join(world.home, '.kogen/credentials/chatgpt.json');
  return fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : null;
}

function createCredentials(world, expired) {
  const directory = path.join(world.home, '.kogen/credentials');
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  fs.chmodSync(path.dirname(directory), 0o700);
  fs.chmodSync(directory, 0o700);
  const now = Math.floor(Date.now() / 1000);
  const credential = {
    client_id: 'oaiapp_test',
    access_token: FAKE_ACCESS_TOKEN,
    refresh_token: FAKE_REFRESH_TOKEN,
    expires_at: expired ? now - 3600 : now + 3600,
    scope: DEFAULT_SCOPE,
    email: 'user@example.com',
  };
  fs.writeFileSync(path.join(directory, 'chatgpt.json'), `${JSON.stringify(credential)}\n`, { mode: 0o600 });
  fs.chmodSync(path.join(directory, 'chatgpt.json'), 0o600);
  fs.writeFileSync(path.join(world.home, '.kogen/host-id'), 'urn:uuid:8c7d7b11-9300-4d5c-9aab-b46e1515ac11\n', { mode: 0o600 });
}

function extractArchive(world) {
  const dir = path.join(world.workspace, `release-${crypto.randomBytes(4).toString('hex')}`);
  const source = path.join(dir, path.basename(world.sharedSource));
  // BeforeAll already extracted these archive bytes with tar. Give each installer
  // its own copy; clone file data where supported, otherwise copy it normally.
  fs.cpSync(world.sharedSource, source, {
    recursive: true, dereference: false, verbatimSymlinks: true,
    preserveTimestamps: true, mode: fs.constants.COPYFILE_FICLONE,
  });
  world.archiveDir = source;
  return source;
}

async function serveNodeDistribution(world) {
  const version = execFileSync(path.join(NODE24, 'node'), ['--version'], { encoding: 'utf8' }).trim();
  const root = path.dirname(NODE24);
  const archive = path.join(world.workspace, 'node-distribution.tar.gz');
  // Archive Node's payload, not separately installed global tools beside npm.
  const payload = ['bin/node', 'bin/npm', 'bin/npx', 'lib/node_modules/npm',
    'include', 'share', 'LICENSE', 'README.md', 'CHANGELOG.md'];
  if (fs.existsSync(path.join(root, 'bin/corepack'))) {
    payload.push('bin/corepack', 'lib/node_modules/corepack');
  }
  execFileSync('tar', ['-czf', archive, '-C', path.dirname(root),
    ...payload.map(entry => `${path.basename(root)}/${entry}`)], {
    env: { ...process.env, GZIP: '-1' },
  });
  const dist = process.platform === 'darwin' ? 'darwin-arm64' : 'linux-x64';
  const archivePath = `/${version}/node-${version}-${dist}.tar.gz`;
  const catalog = [
    'version\tdate\tfiles\tnpm\tv8\tuv\tzlib\topenssl\tmodules\tlts\tsecurity',
    `v999.0.0\t2099-01-01\t${dist}\t-\t-\t-\t-\t-\t-\t-\tfalse`,
    `${version}\t2026-01-01\t${dist}\t-\t-\t-\t-\t-\t-\tKrypton\tfalse`,
    '',
  ].join('\n');
  const requests = [];
  const server = http.createServer((req, res) => {
    requests.push(req.url);
    if (req.url === '/index.tab') res.end(catalog);
    else if (req.url === archivePath) fs.createReadStream(archive).pipe(res);
    else { res.statusCode = 404; res.end('Unknown Node distribution'); }
  });
  world.nodeDistribution = { server, requests, version, archivePath };
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  world.extraEnv.KOGEN_TEST_NODE_DISTRIBUTION_URL = `http://127.0.0.1:${server.address().port}`;
}

function pathInside(root, file) {
  const rel = path.relative(root, file);
  return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel));
}

function checkNoToken(root, token) {
  for (const entry of walkFiles(root)) {
    if (entry.symlink) continue;
    const bytes = safeRead(entry.path);
    if (bytes && bytes.includes(Buffer.from(token))) return false;
  }
  return true;
}

function changedPathsInCommit(world, root = world.project) {
  return git(world, ['diff-tree', '--no-commit-id', '--name-only', '-r', 'HEAD'], root).split('\n').filter(Boolean).sort();
}

function assertNewCommit(world) {
  const baseline = world.buildStartHead ?? world.headBeforeLastCommand;
  const headResult = world.git(world.buildProject || world.project, ['rev-parse', '--verify', 'HEAD']);
  assert.equal(headResult.status, 0, 'HEAD does not resolve to a commit');
  const head = headResult.stdout.trim();
  assert.notEqual(head, baseline, 'HEAD did not move after the When command');
  const parent = world.git(world.buildProject || world.project, ['rev-parse', '--verify', 'HEAD^']);
  if (baseline) {
    assert.equal(parent.status, 0, 'the new HEAD has no parent');
    assert.equal(parent.stdout.trim(), baseline, 'the new commit is not a direct child of the HEAD before the When command');
  } else {
    assert.notEqual(parent.status, 0, 'the Initial commit unexpectedly has a parent');
  }
  return head;
}

const liveOnly = new Set([
  'the caller runs kogen init and configures the project\'s commands',
  'the caller signs in with the real ChatGPT browser flow and kogen provider list shows the login',
  'the caller shapes the project\'s request and answers any question it asks',
  'the caller reviews the Intent and step files and approves them',
  'the caller starts the Build and sends SIGINT during it',
  'the Build stops within 15 seconds with exit code 130 and no commit',
  'the caller discards the listed edits and builds again',
  'the Build runs at least one tool call, lands with review approved and the transcript records whether a repair happened',
  'the project\'s own acceptance command and tests pass on the new commit without Kogen',
  'the new commit has the Intent title, the Kogen-Intent trailer, no AI attribution and a signature exactly as the host\'s Git configuration says',
  'no Kogen process is alive and no credential token appears in any project or log file',
  'the release archive downloaded with curl and installed with install.sh',
  'the full deterministic suite and the packaging run from that checkout',
  'the candidate\'s deterministic suite passes with an isolated HOME and no real credentials',
  'the candidate is packaged, installed into a separate prefix and the change is observed outside its checkout',
  'the installed Kogen shapes and builds one small Kogen change there',
  'a clean checkout of the release commit',
  'no required scenario is pending, skipped, undefined or excluded and spec/check.sh passes',
  'the release built from that checkout reports the commit\'s short hash',
  'kogen is gone and the project and ~/.kogen are intact',
]);
const livePrefixes = ['a fresh user home on ', 'a fresh clone of ', 'a disposable repository with the candidate Kogen source'];

function refuseLiveStep(label) {
  if (liveOnly.has(label) || livePrefixes.some(prefix => label.startsWith(prefix))) {
    throw new Error(`"${label}" belongs to the @live release acceptance: run test/live/real-use.sh`);
  }
}

async function dispatch(world, pattern, values, attachment) {
  const label = plainPattern(pattern);
  const args = values;
  refuseLiveStep(label);
  const result = () => lastResult(world);
  const root = () => world.project || world.workspace;

  if (label === 'a clean Kogen home') {
    assert.ok(world.home && fs.existsSync(world.home));
    assert.ok(!fs.existsSync(path.join(world.home, '.kogen/credentials/chatgpt.json')));
    return;
  }
  if (label === 'the installed kogen command') {
    assert.ok(fs.existsSync(path.join(world.prefix, 'bin/kogen')));
    world.commandOverride = null;
    return;
  }
  if (label.startsWith('a Git project from fixture ')) {
    const folder = args.length > 1 ? args[1] : undefined;
    await world.createProject(args[0], folder);
    return;
  }
  if (label === 'the project is initialized') {
    await initProject(world, false);
    return;
  }
  if (label === 'the project is initialized and configured') {
    await initProject(world, true);
    return;
  }
  if (label.startsWith('the project config sets ')) {
    setConfigKey(world, args[0], args[1]);
    return;
  }
  if (label === 'the acceptance command records its environment') {
    installAcceptanceRunner(world, 'record');
    return;
  }
  if (label.startsWith('the acceptance command is replaced by fixture runner ')) {
    installAcceptanceRunner(world, args[0]);
    return;
  }
  if (label.startsWith('the Intent ')) {
    const slug = args[0];
    const fixture = args[1];
    world.intentSlug = slug;
    copyIntent(world, slug, fixture);
    if (label.includes('is shaped')) return;
    if (label.includes('is approved and then edited')) {
      await approveThroughKogen(world, slug);
      fs.appendFileSync(intentSourceFile(world, slug, 'intent.md'), '\nA caller edit after approval.\n');
      return;
    }
    if (label.includes('is approved')) {
      await approveThroughKogen(world, slug);
      return;
    }
    if (label.includes('has landed')) {
      await approveThroughKogen(world, slug);
      world.server.configure('build-correct-first-try');
      const landed = await runProduct(world, `kogen intent build ${slug}`, { cwd: world.project });
      assert.equal(landed.code, 0, landed.stdout + landed.stderr);
      world.lastResult = landed;
      rememberBaseline(world, slug);
      world.server.configure('build-correct-first-try');
      return;
    }
    throw new Error(`Intent setup is not implemented: ${label}`);
  }
  if (label === 'no Intent named is-even exists') {
    fs.rmSync(projectFile(world, '.kogen/intents/is-even'), { recursive: true, force: true });
    return;
  }
  if (label.startsWith('the caller noted the review card hash of ')) {
    const slug = args[0];
    const card = await runProduct(world, `kogen intent approve ${slug}`, { cwd: world.project });
    assert.equal(card.code, 5, card.stdout + card.stderr);
    const hash = card.stdout.match(/^SHA-256: ([0-9a-f]{64})$/m)?.[1];
    assert.ok(hash, 'review card has no full SHA-256');
    assert.equal(hash, baselineHash(world, slug), `review card SHA-256 differs from the acceptance baseline for ${slug}`);
    world.notedHashes.set(slug, hash);
    world.reviewCardHashes.set(slug, hash);
    return;
  }
  if (label.startsWith('the caller approves ')) {
    const slug = args[0];
    let hash;
    if (label.includes('with the hash from its review card')) {
      const card = await runProduct(world, `kogen intent approve ${slug}`, { cwd: world.project });
      assert.equal(card.code, 5, card.stdout + card.stderr);
      hash = card.stdout.match(/^SHA-256: ([0-9a-f]{64})$/m)?.[1];
      assert.ok(hash, 'review card has no full SHA-256');
      assert.equal(hash, baselineHash(world, slug), `review card SHA-256 differs from the acceptance baseline for ${slug}`);
      world.reviewCardHashes.set(slug, hash);
    } else if (label.includes('with the hash of its acceptance baseline')) {
      hash = baselineHash(world, slug);
    } else {
      hash = world.notedHashes.get(slug);
    }
    assert.ok(hash, 'the approval hash was not available');
    const approved = await runProduct(world, `kogen intent approve ${slug} ${hash}`, { cwd: world.project });
    world.lastResult = approved;
    return;
  }
  if (label.startsWith('the original refinement readiness receipt has status ')) {
    const base = path.join(world.project, '.kogen/local/refinements');
    const receipts = fs.readdirSync(base).map(id => path.join(base, id, 'original-readiness.json')).filter(p => fs.existsSync(p)).map(p => JSON.parse(fs.readFileSync(p, 'utf8')));
    assert.ok(receipts.some(r => r.status === args[0] && r.source === 'retained' && r.setup_executions === 0 && r.acceptance_executions === 0 && r.model_executions === 0));
    return;
  }
  if (label.startsWith('the caller refines ')) {
    const slug = args[0];
    await runProduct(world, `kogen intent refine ${slug} ${baselineHash(world, slug)} -`, { cwd: world.project, stdin: String(attachment ?? '') });
    return;
  }
  if (label === 'the caller is signed in to ChatGPT') {
    createCredentials(world, false);
    return;
  }
  if (label === 'the caller is signed in to ChatGPT with an expired access token') {
    createCredentials(world, true);
    return;
  }
  if (label === 'the caller is signed out of ChatGPT') {
    fs.rmSync(path.join(world.home, '.kogen/credentials/chatgpt.json'), { force: true });
    return;
  }
  if (label.startsWith('the file ') && label.includes('holds a ChatGPT token')) {
    const file = filePath(world, args[0]);
    mkdirp(path.dirname(file));
    fs.writeFileSync(file, JSON.stringify({ access_token: args[1] }) + '\n', { mode: 0o600 });
    return;
  }
  if (label.startsWith('the file ') && label.includes(' contains:')) {
    const file = filePath(world, args[0]);
    mkdirp(path.dirname(file));
    fs.writeFileSync(file, String(attachment ?? ''));
    return;
  }
  if (label.startsWith('the committed file ')) {
    const file = projectFile(world, args[0]);
    mkdirp(path.dirname(file));
    fs.writeFileSync(file, `${args[1]}\n`);
    git(world, ['add', '--', args[0]]);
    const committed = world.git(world.project, ['commit', '-q', '-m', `Add ${args[0]} fixture`]);
    assert.equal(committed.status, 0, committed.stderr || committed.stdout);
    return;
  }
  if (label === 'another commit is made on HEAD') {
    const file = projectFile(world, 'caller-change.txt');
    fs.writeFileSync(file, 'a separate commit made while Kogen was waiting\n');
    git(world, ['add', '--', 'caller-change.txt']);
    const committed = world.git(world.project, ['commit', '-q', '-m', 'Caller change during Build']);
    assert.equal(committed.status, 0, committed.stderr || committed.stdout);
    return;
  }
  if (label.startsWith('the fake authorization server grants only ')) {
    world.server.setGrant(args[0]);
    return;
  }
  if (label === 'the authorization server rejects refresh') {
    world.server.rejectNextRefresh();
    return;
  }
  if (label === 'the fake ChatGPT authorization server is running') {
    assert.ok(world.server.providerUrl && world.server.authUrl);
    return;
  }
  if (label.startsWith('the fake ChatGPT server plays script ')) {
    const name = args[0];
    let pauseAt = null;
    let scriptArgs = {};
    if (label.includes(' pausing at ')) pauseAt = args[1];
    if (label.includes(' with command ')) scriptArgs.command = args[1];
    if (label.includes(' with path ')) scriptArgs.path = args[1];
    world.server.configure(name, pauseAt, scriptArgs);
    return;
  }
  if (label === 'the fake ChatGPT server continues') {
    world.server.continue();
    return;
  }
  if (label === 'the readiness command is running') {
    const start = Date.now();
    while (!fs.existsSync(world.runningPidFile) && Date.now() - start < 30000) await new Promise(resolve => setTimeout(resolve, 20));
    assert.ok(fs.existsSync(world.runningPidFile), 'readiness command did not reach its running marker');
    const [pid, ppid, pgid] = fs.readFileSync(world.runningPidFile, 'utf8').trim().split(/\s+/).map(Number);
    world.trackCoreGroups();
    const group = world.trackProcessGroup(pid, ppid, pgid);
    assert.ok(group, `readiness command process group was not recorded (pid=${pid}, ppid=${ppid}, pgid=${pgid})`);
    assert.ok(world.processGroupAlive(group), `readiness command process group was not alive when captured (pgid=${pgid})`);
    return;
  }
  if (label.startsWith('the caller runs "') && label.includes(' with the sign-in redirect URL on stdin')) {
    const command = args[0];
    const record = await world.invoke(command, { cwd: world.project || world.workspace, background: true, keepStdin: true });
    world.currentProcess = record;
    const authorizeUrl = await waitForAuthorizationUrl(record);
    const redirect = await getWithoutRedirect(authorizeUrl);
    assert.equal(redirect.status, 302);
    assert.ok(redirect.location);
    record.child.stdin.write(`${redirect.location}\n`);
    record.child.stdin.end();
    await record.done;
    world.remember(record);
    world.currentProcess = null;
    return;
  }
  if (label.startsWith('the browser completes sign-in for ')) {
    const record = world.currentProcess;
    assert.ok(record, 'no login command is running');
    const authorizeUrl = await waitForAuthorizationUrl(record);
    const authorize = await getWithoutRedirect(authorizeUrl);
    assert.equal(authorize.status, 302);
    assert.ok(authorize.location);
    const response = await getWithoutRedirect(authorize.location);
    assert.ok(response.status >= 200 && response.status < 400);
    return;
  }
  if (label === 'the browser sends a redirect with the wrong state') {
    const record = world.currentProcess;
    const authorizeUrl = await waitForAuthorizationUrl(record);
    const authorize = await getWithoutRedirect(authorizeUrl);
    assert.equal(authorize.status, 302);
    const wrong = new URL(authorize.location);
    wrong.searchParams.set('state', 'wrong-state');
    await getWithoutRedirect(wrong.toString());
    return;
  }
  if (label === 'the authorization request used PKCE S256 and a fresh state') {
    const request = world.server.authorizeRequests.at(-1);
    assert.ok(request, 'no authorization request reached the fake server');
    assert.equal(request.code_challenge_method, 'S256');
    assert.match(request.code_challenge || '', /^[A-Za-z0-9_-]{43}$/);
    assert.ok(request.state && request.nonce);
    if (!world.seenStates) world.seenStates = new Set();
    assert.ok(!world.seenStates.has(request.state), 'OAuth state was reused');
    world.seenStates.add(request.state);
    return;
  }
  if (label.startsWith('the installed core shapes "')) {
    const go = findProgram('go');
    assert.ok(go, 'Go is required to build the test-only deadline driver');
    const driver = path.join(world.workspace, 'probe-deadline-test');
    execFileSync(go, ['test', '-c', '-o', driver], {
      cwd: path.join(ACCEPTANCE, '../../cli'),
      env: process.env,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const installRoot = path.join(world.prefix, 'lib/kogen');
    const requestFile = path.join(world.workspace, 'probe-deadline-request.json');
    world.probeDeadlineReceipt = path.join(world.workspace, 'probe-deadline-receipt.json');
    world.requestText = String(attachment ?? '');
    const env = {
      ...world.env(),
      KOGEN_NODE: fs.readFileSync(path.join(installRoot, 'node-path'), 'utf8').trim(),
      KOGEN_CUCUMBER: path.join(installRoot, 'lib/cucumber/node_modules'),
    };
    fs.writeFileSync(requestFile, JSON.stringify({
      type: 'run', command: 'shape', project: world.project, slug: args[0],
      input: world.requestText, cwd: world.project, install_root: installRoot, env,
    }));
    await world.invoke('-test.run=^TestInstalledProbeDeadline$ -test.timeout=60s', {
      executableOverride: driver,
      env: {
        KOGEN_TEST_PROBE_DEADLINE: '1', KOGEN_TEST_ROOT: installRoot,
        KOGEN_TEST_PROBE_REQUEST: requestFile, KOGEN_TEST_PROBE_RECEIPT: world.probeDeadlineReceipt,
      },
    });
    return;
  }
  if (label.startsWith('the caller runs "')) {
    const command = args[0];
    if (label.includes(' and ') && label.includes(' at the same time with stdin:')) {
      const input = String(attachment ?? '');
      world.requestText = input;
      const first = await runProduct(world, command, { cwd: world.project || world.workspace, stdin: input, background: true });
      const second = await runProduct(world, args[1], { cwd: world.project || world.workspace, stdin: input, background: true });
      const [a, b] = await Promise.all([first.done, second.done]);
      world.multiResults = [a, b];
      world.remember(b);
      return;
    }
    if (label.includes(' in the background')) {
      await runProduct(world, command, { cwd: world.project || world.archiveDir || world.workspace, background: true });
      return;
    }
    if (label.includes(' with stdin:')) {
      world.requestText = String(attachment ?? '');
      await runProduct(world, command, { cwd: world.project || world.archiveDir || world.workspace, stdin: world.requestText });
      return;
    }
    if (label.includes(' with stdin "')) {
      world.requestText = args[1];
      await runProduct(world, command, { cwd: world.project || world.archiveDir || world.workspace, stdin: world.requestText });
      return;
    }
    if (label.includes(' in the folder ')) {
      const folder = args[1];
      const cwd = path.isAbsolute(folder) ? folder : path.resolve(world.project || world.workspace, folder);
      await runProduct(world, command, { cwd });
      return;
    }
    const commandResult = await runProduct(world, command, { cwd: world.project || world.archiveDir || world.workspace });
    if (command === 'sh install.sh') {
      world.installPrefix = path.join(world.home, '.local');
      world.prefix = world.installPrefix;
    }
    world.lastResult = commandResult;
    return;
  }
  if (label.startsWith('the caller ran "')) {
    const command = args[0];
    if (command === 'sh install.sh') {
      const installed = await runProduct(world, command, { cwd: world.archiveDir || world.workspace });
      world.installPrefix = path.join(world.home, '.local');
      world.prefix = world.installPrefix;
      world.lastResult = installed;
      return;
    }
    const options = { cwd: world.project || world.archiveDir || world.workspace };
    if (label.includes(' with stdin "')) {
      options.stdin = args[1];
      world.requestText = args[1];
    }
    await runProduct(world, command, options);
    return;
  }
  if (label === 'the caller runs kogen uninstall') {
    await runProduct(world, `${world.home}/.local/bin/kogen uninstall`, { cwd: world.project || world.workspace });
    return;
  }
  return dispatchAssertions(world, label, args, attachment);
}

async function dispatchAssertions(world, label, args, attachment) {
  const actual = () => lastResult(world);
  const resultTemplate = value => assertContainsTemplate(world, actual().stdout, value, 'stdout');
  const stderrTemplate = value => assertContainsTemplate(world, actual().stderr, value, 'stderr');

  if (label.startsWith('HEAD has ') && label.includes(' new commit')) {
    const baseline = world.buildStartHead || world.headBeforeLastCommand;
    assert.ok(baseline, 'there was no HEAD before the command');
    assertNewCommit(world);
    const count = git(world, ['rev-list', '--count', `${baseline}..HEAD`]);
    assert.equal(Number(count), Number(args[0]));
    return;
  }
  if (label === 'HEAD has no commit by Kogen') {
    const message = git(world, ['log', '-1', '--format=%B']);
    assert.ok(!/^Kogen-Intent:/m.test(message), 'HEAD has a Kogen-Intent trailer');
    return;
  }
  if (label === 'HEAD is unchanged') {
    const baseline = world.headBeforeLastCommand;
    assert.equal(world.head(world.project), baseline);
    return;
  }
  if (label === 'the new commit changes exactly:') {
    assertNewCommit(world);
    const rows = parseTable(attachment).slice(1).map(row => row[0]).filter(Boolean).sort();
    assert.deepEqual(changedPathsInCommit(world), rows);
    return;
  }
  if (label === 'the new commit\'s message is:') {
    assertNewCommit(world);
    const expected = String(attachment ?? '').trimEnd();
    const actualMessage = git(world, ['log', '-1', '--format=%B']).trimEnd();
    assert.equal(actualMessage, expected);
    return;
  }
  if (label === 'the new commit is signed') {
    assertNewCommit(world);
    assert.ok(world.allowedSignersFile, 'the test allowed-signers file was not configured');
    const verified = world.git(world.project, ['-c', `gpg.ssh.allowedSignersFile=${world.allowedSignersFile}`, 'verify-commit', 'HEAD']);
    assert.equal(verified.status, 0, verified.stderr || verified.stdout || 'git verify-commit rejected HEAD');
    return;
  }
  if (label === 'the new commit is not signed') {
    assertNewCommit(world);
    const object = git(world, ['cat-file', '-p', 'HEAD']);
    assert.doesNotMatch(object, /^gpgsig /m);
    return;
  }
  if (label.startsWith('the new commit changes no path under ')) {
    assertNewCommit(world);
    const prefix = args[0].replace(/\/$/, '');
    assert.ok(!changedPathsInCommit(world).some(item => item === prefix || item.startsWith(`${prefix}/`)));
    return;
  }
  if (label.startsWith('the new commit changes ')) {
    assertNewCommit(world);
    assert.ok(changedPathsInCommit(world).includes(args[0]), `${args[0]} was not in the commit`);
    return;
  }
  if (label.startsWith('the new commit does not change ')) {
    assertNewCommit(world);
    assert.ok(!changedPathsInCommit(world).includes(args[0]), `${args[0]} was in the commit`);
    return;
  }
  if (label === 'nothing is staged') {
    assert.equal(git(world, ['diff', '--cached', '--name-only']), '');
    return;
  }
  if (label === 'no review request was sent') {
    assert.equal(world.server.requests.filter(request => request.kind === 'review').length, 0);
    return;
  }
  if (label === 'no request was sent after that command') {
    const call = world.server.responseItems.find(item => item.name === 'shell' && item.kind === 'build');
    assert.ok(call, 'the builder did not call a shell command');
    assert.ok(!world.server.requests.some(request => request.order > call.requestOrder));
    return;
  }
  if (label === 'no Kogen git invocation disabled signing or hooks') {
    const entries = fs.existsSync(world.gitLog) ? fs.readFileSync(world.gitLog, 'utf8').split(/\r?\n/).filter(Boolean) : [];
    assert.ok(entries.some(line => /\bcommit\b/.test(line)), 'no Kogen commit invocation was logged');
    assert.ok(!entries.some(line => /(?:--no-gpg-sign|(?:^|\s)(?:-n|--no-verify)(?:\s|$)|commit\.gpgsign\s*=\s*false|core\.hooksPath\s*=\s*(?:\/dev\/null|"?"?))/i.test(line)));
    return;
  }
  if (label.startsWith('no Kogen git invocation used ')) {
    const entries = fs.existsSync(world.gitLog) ? fs.readFileSync(world.gitLog, 'utf8').split(/\r?\n/).filter(Boolean) : [];
    assert.ok(entries.some(line => /\bcommit\b/.test(line)), 'no Kogen commit invocation was logged');
    const forbidden = /(?:^|\s)(?:push|fetch|rebase|merge|cherry-pick|reset|stash|switch|checkout)(?:\s|$)|\bcommit\b.*--amend/;
    assert.ok(!entries.some(line => forbidden.test(line)), entries.join('\n'));
    return;
  }

  if (label.startsWith('an empty folder ')) {
    const dir = path.join(world.workspace, args[0]);
    mkdirp(dir);
    world.emptyFolders.set(args[0], dir);
    return;
  }
  if (label.startsWith('the release archive for this platform')) {
    extractArchive(world);
    return;
  }
  if (label.startsWith('the extracted archive has a broken core release')) {
    assert.ok(world.archiveDir, 'extract the release archive first');
    fs.rmSync(path.join(world.archiveDir, 'lib/release/bin/kogen'), { force: true });
    return;
  }
  if (label === 'the installed core release is missing') {
    const source = extractArchive(world);
    const prefix = path.join(world.workspace, 'missing-core-prefix');
    execFileSync('/bin/sh', [path.join(source, 'install.sh'), '--prefix', prefix], {
      cwd: source,
      env: world.env(),
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    fs.rmSync(path.join(prefix, 'lib/kogen/lib/release/bin/kogen'), { force: true });
    world.prefix = prefix;
    return;
  }
  if (label === 'the caller ran "sh install.sh"') {
    await runProduct(world, 'sh install.sh', { cwd: world.archiveDir || world.workspace });
    world.installPrefix = path.join(world.home, '.local');
    world.prefix = world.installPrefix;
    return;
  }
  if (label === 'a local Node distribution serves the real pinned Node and a newer non-LTS catalog entry') {
    await serveNodeDistribution(world);
    return;
  }
  if (label === 'the installer downloaded the catalog and selected LTS archive from the local Node distribution') {
    const fixture = world.nodeDistribution;
    assert.ok(fixture, 'the local Node distribution must be running');
    assert.deepEqual(fixture.requests, ['/index.tab', fixture.archivePath]);
    return;
  }
  if (label === 'the installed Node reports the real fixture version') {
    const node = path.join(world.home, '.local/lib/kogen/node/bin/node');
    assert.equal(execFileSync(node, ['--version'], { encoding: 'utf8' }).trim(), world.nodeDistribution.version);
    return;
  }
  if (label === 'no erl, elixir or go program is on PATH') {
    world.hiddenPrograms.add('erl');
    world.hiddenPrograms.add('elixir');
    world.hiddenPrograms.add('go');
    return;
  }
  if (label.startsWith('the program ')) {
    const program = args[0];
    if (program === 'node') world.hiddenPrograms.add(program);
    else {
      const current = world.basePath();
      assert.equal(findProgram(program, current), null, `${program} unexpectedly exists on PATH`);
      world.hiddenPrograms.add(program);
    }
    return;
  }
  if (label.startsWith('uname reports ')) {
    const toolPath = path.join(world.workspace, 'fake-platform-tools');
    mkdirp(toolPath);
    const uname = path.join(toolPath, 'uname');
    fs.writeFileSync(uname, `#!/bin/sh\nif [ "$1" = "-s" ]; then printf '%s\\n' ${shellQuote(args[0])}; else printf '%s\\n' ${shellQuote(args[1])}; fi\n`);
    fs.chmodSync(uname, 0o755);
    world.toolPath = toolPath;
    return;
  }
  if (label === 'node 22 or newer is on PATH') {
    const node = path.join(NODE24, 'node');
    const out = execFileSync(node, ['-p', 'process.execPath'], { encoding: 'utf8' }).trim();
    assert.ok(out.startsWith(NODE24));
    world.nodePath = out;
    world.hiddenPrograms.delete('node');
    return;
  }
  if (label.startsWith('a broken program ')) {
    const program = args[0];
    world.toolPath = path.join(world.workspace, 'broken-tools');
    mkdirp(world.toolPath);
    const file = path.join(world.toolPath, program);
    const runnerFallback = program === 'node'
      ? `case "$1" in */cucumber-js|cucumber-js) exec ${shellQuote(path.join(NODE24, 'node'))} "$@" ;; esac\n`
      : '';
    fs.writeFileSync(file, `#!/bin/sh\n${runnerFallback}exit 97\n`);
    fs.chmodSync(file, 0o755);
    return;
  }
  if (label.startsWith('the environment variable ')) {
    if (!world.extraEnv) world.extraEnv = {};
    world.extraEnv[args[0]] = args[1];
    return;
  }
  if (label === 'git user.name and user.email are not set') {
    world.setIdentity(false);
    return;
  }
  if (label === 'a merge is in progress') {
    const gitDir = world.gitDir();
    fs.writeFileSync(path.join(gitDir, 'MERGE_HEAD'), `${'0'.repeat(40)}\n`);
    return;
  }
  if (label === 'the project has a build lock of a process that is not running') {
    const lock = projectFile(world, '.kogen/local/build.lock');
    mkdirp(path.dirname(lock));
    fs.writeFileSync(lock, '987654321\n');
    return;
  }
  if (label === 'a commit-msg hook that rejects every message') {
    installHook(world, 'commit-msg', '#!/bin/sh\necho "commit-msg: this message is not allowed" >&2\nexit 1\n');
    return;
  }
  if (label.startsWith('a pre-commit hook that sleeps for ')) {
    world.preCommitMarker = path.join(world.workspace, 'pre-commit-running.marker');
    installHook(world, 'pre-commit', `#!/bin/sh\nprintf '%s %s %s\\n' "$$" "$PPID" "$(kogen-pgid)" > ${shellQuote(world.preCommitMarker)}\nsleep ${args[0]}\n`);
    return;
  }
  if (label.startsWith('a pre-commit hook that appends a line to ')) {
    const rel = args[0];
    installHook(world, 'pre-commit', `#!/bin/sh\nprintf '%s\\n' 'changed by pre-commit hook' >> ${shellQuote(rel)}\ngit add -- ${shellQuote(rel)}\n`);
    return;
  }
  if (label === 'the test build of the core pauses right after creating the commit') {
    const marker = path.join(world.workspace, 'post-commit-paused.marker');
    world.postCommitMarker = marker;
    installHook(world, 'post-commit', `#!/bin/sh\nprintf '%s %s %s\\n' "$$" "$PPID" "$(kogen-pgid)" > ${shellQuote(marker)}\nsleep 600\n`);
    return;
  }
  if (label.startsWith('commit signing is configured with a test SSH key')) {
    configureSigning(world, false);
    return;
  }
  if (label.startsWith('commit signing is configured with a missing key')) {
    configureSigning(world, true);
    return;
  }
  if (label === 'the Kogen core logs at debug level') {
    world.extraEnv.ERL_AFLAGS = '-kernel logger_level debug';
    world.extraEnv.KOGEN_LOG_LEVEL = 'debug';
    return;
  }
  if (label.startsWith('the fake ChatGPT server reaches ')) {
    await reachPause(world, args[0]);
    return;
  }
  if (label.startsWith('the fake ChatGPT server has sent the feedback of verification pass ')) {
    const n = Number(args[0]);
    // Each pass is a real verification of the installed release; allow 5 s per pass on a loaded host.
    await waitForServerRequest(world, request => request.text.includes(`Verification pass ${n} is not green.`), Math.max(30000, n * 5000));
    return;
  }

  if (label.startsWith('the Build reaches ')) {
    await reachPause(world, args[0]);
    return;
  }
  if (label === 'the background command finishes') {
    await world.waitFor(world.currentProcess, 15 * 60 * 1000);
    return;
  }
  if (label.startsWith('the caller sends ')) {
    const signal = args.at(-1);
    const record = world.currentProcess;
    world.lastResult = record;
    if (label.includes('to the Kogen core')) {
      const pid = await findCorePid(world);
      process.kill(pid, signal);
    } else {
      world.sendSignal(record, signal);
      await world.waitFor(record, 15000);
      world.lastResult = record;
    }
    return;
  }
  if (label === 'the kogen command is still running') {
    const record = world.currentProcess;
    await new Promise(resolve => setTimeout(resolve, 2000));
    assert.ok(record && record.child.exitCode === null && record.child.signalCode === null, 'the kogen command has exited');
    process.kill(record.child.pid, 0);
    return;
  }
  if (label.startsWith('within ')) {
    if (label.includes('the kogen command has exited')) {
      const seconds = Number(args[0]);
      const record = world.currentProcess || world.lastResult;
      assert.ok(record, 'no Kogen command result is available');
      if (record.code === null) await world.waitFor(record, seconds * 1000);
      else assert.ok(record.code !== null, 'the kogen command has not exited');
      return;
    }
    if (label.includes('no process of the Build command')) {
      const seconds = Number(args[0]);
      const start = Date.now();
      await world.verifyWatchedCommandGroups();
      const groups = new Set([...world.kogenGroups, ...world.commandGroups]);
      assert.ok(groups.size, 'no Build command process group was recorded');
      while (Date.now() - start < seconds * 1000) {
        if (![...groups].some(group => world.processGroupAlive(group))) return;
        await new Promise(resolve => setTimeout(resolve, 100));
      }
      assert.fail('a process in the Build command process group is still running');
    }
  }
  if (label.startsWith('the core reaches the pause after the commit')) {
    const start = Date.now();
    while (!fs.existsSync(world.postCommitMarker) && Date.now() - start < 30000) await new Promise(resolve => setTimeout(resolve, 20));
    assert.ok(fs.existsSync(world.postCommitMarker), 'post-commit hook did not reach its pause');
    const [pid, ppid, pgid] = fs.readFileSync(world.postCommitMarker, 'utf8').trim().split(/\s+/).map(Number);
    world.trackProcessGroup(pid, ppid, pgid);
    return;
  }
  if (label === 'both commands exit 0') {
    const actualCodes = (world.multiResults || []).map(item => item.code);
    const output = (world.multiResults || []).map((item, index) => `command ${index + 1} (exit ${item.code})\nstdout:\n${item.stdout}\nstderr:\n${item.stderr}`).join('\n--- next command ---\n');
    assert.deepEqual(actualCodes, [0, 0], output);
    return;
  }
  if (label.startsWith('the exit code is ')) {
    if (world.currentProcess && (!world.lastResult || world.lastResult === world.currentProcess) && world.currentProcess.code === null) await world.waitFor(world.currentProcess, 15000);
    assert.equal(actual().code, Number(args[0]), `${actual().stdout}${actual().stderr}`);
    return;
  }
  if (label.startsWith('stdout contains ')) {
    assertContainsTemplate(world, actual().stdout, args[0], 'stdout');
    return;
  }
  if (label === 'stdout contains:') {
    assertContainsTemplate(world, actual().stdout, String(attachment ?? ''), 'stdout');
    return;
  }
  if (label.startsWith('stdout does not contain ')) {
    assert.ok(!actual().stdout.includes(args[0]), `stdout unexpectedly contained ${args[0]}`);
    return;
  }
  if (label === 'stdout is:') {
    exactTemplate(world, actual().stdout, String(attachment ?? ''), 'stdout');
    return;
  }
  if (label.startsWith('stdout matches ')) {
    const source = args[0].replace(/\$$/, '(?:\\r?\\n)?$');
    assert.match(actual().stdout, new RegExp(source));
    return;
  }
  if (label.startsWith('the first line of stdout is ')) {
    const first = actual().stdout.split(/\r?\n/)[0];
    assert.match(first, outputPattern(world, args[0]));
    return;
  }
  if (label.startsWith('the last line of stdout matches ')) {
    const lines = actual().stdout.trimEnd().split(/\r?\n/);
    assert.match(lines.at(-1), new RegExp(args[0]));
    return;
  }
  if (label.startsWith('the rest of stdout after a blank line is the help page ')) {
    const page = args[0];
    const expected = page === 'top' ? topHelp : page === 'intent' ? intentHelp : providerHelp;
    const separator = actual().stdout.match(/\r?\n\r?\n/);
    assert.ok(separator, 'stdout did not contain a blank line');
    const rest = actual().stdout.slice(separator.index + separator[0].length);
    assert.equal(rest, expected);
    return;
  }
  if (label.startsWith('stderr contains ')) {
    if (label === 'stderr contains core log lines') assert.match(actual().stderr, /\[debug\]/i);
    else assertContainsTemplate(world, actual().stderr, args[0], 'stderr');
    return;
  }
  if (label.startsWith('stderr matches ')) {
    assert.match(actual().stderr, new RegExp(args[0]));
    return;
  }
  if (label.startsWith('the file ') || label.startsWith('the folder ')) {
    return fileAssertions(world, label, args, attachment, actual);
  }
  if (label.startsWith('the path ')) {
    const target = filePath(world, args[0]);
    const changed = statusPaths(world).includes(path.relative(world.project, target).split(path.sep).join('/'));
    assert.equal(changed, true, `${args[0]} does not have uncommitted changes`);
    return;
  }
  if (label.startsWith('the project has the Kogen configuration and ignore line written but not committed')) {
    const configFile = projectFile(world, '.kogen/project.yaml');
    mkdirp(path.dirname(configFile));
    fs.writeFileSync(configFile, initTemplate());
    const ignore = projectFile(world, '.gitignore');
    let text = fs.existsSync(ignore) ? fs.readFileSync(ignore, 'utf8') : '';
    if (!text.split(/\r?\n/).includes('.kogen/local/')) text += `${text && !text.endsWith('\n') ? '\n' : ''}.kogen/local/\n`;
    fs.writeFileSync(ignore, text);
    return;
  }
  if (label === 'the working tree is unchanged') {
    const paths = statusPaths(world);
    assert.deepEqual(paths, []);
    return;
  }
  if (label === 'the working tree has no changes outside the Intent\'s files') {
    const ownFolder = `.kogen/intents/${world.intentSlug}/`;
    const allowed = new Set(acceptanceFiles(world, world.intentSlug));
    const changed = statusPaths(world);
    const outside = changed.filter(item => !item.startsWith(ownFolder) && !allowed.has(item));
    assert.deepEqual(outside, []);
    return;
  }
  if (label.startsWith('no file in ')) {
    const snapshot = world.homeBeforeInstall || captureFolder(world, args[0]);
    const prefixPath = filePath(world, args[1]);
    const now = new Map(walkFiles(snapshot.root).map(entry => [entry.relative, entry.symlink ? `link:${entry.symlink}` : entry.digest]));
    const changedOutside = new Set([...snapshot.map.keys(), ...now.keys()]);
    for (const rel of changedOutside) {
      const full = path.join(snapshot.root, rel);
      if (pathInside(prefixPath, full)) continue;
      if (snapshot.map.get(rel) !== now.get(rel)) assert.fail(`file outside install prefix changed: ${rel}`);
    }
    return;
  }
  if (label.startsWith('no file under ')) {
    assert.ok(checkNoToken(filePath(world, args[0]), FAKE_ACCESS_TOKEN), 'fake credential token was found in a file');
    return;
  }
  if (label === 'neither stdout nor stderr contains the fake access token') {
    assert.ok(!actual().stdout.includes(FAKE_ACCESS_TOKEN) && !actual().stderr.includes(FAKE_ACCESS_TOKEN));
    return;
  }
  if (label.startsWith('no Kogen process had the fake access token')) {
    const records = [...world.processes].filter(proc => proc.isKogen);
    assert.ok(records.length, 'no Kogen command process was recorded');
    assert.ok(records.some(proc => proc.corePidsObserved.size > 0), 'no Kogen core process was observed');
    const raw = records.flatMap(proc => [...proc.processTexts.values()].flatMap(values => [...values]));
    assert.ok(raw.length, 'no raw process listing was recorded for Kogen descendants');
    assert.ok(raw.every(text => !text.includes(FAKE_ACCESS_TOKEN)), 'fake token appeared in a Kogen process argument or environment');
    return;
  }
  if (label.startsWith('no Kogen process had the request text')) {
    const requestText = world.requestText || 'Add calc.is_even(n).';
    const records = [...world.processes].filter(proc => proc.isKogen);
    assert.ok(records.length, 'no Kogen command process was recorded');
    assert.ok(records.some(proc => proc.corePidsObserved.size > 0), 'no Kogen core process was observed');
    const argumentsSeen = records.flatMap(proc => [...proc.processArguments.values()].flatMap(values => [...values]));
    assert.ok(argumentsSeen.length, 'no raw process arguments were recorded for Kogen descendants');
    assert.ok(argumentsSeen.every(text => !text.includes(requestText)), 'request text appeared in Kogen process arguments');
    return;
  }
  if (label === 'no process of the Build command\'s process group is running') {
    await world.verifyWatchedCommandGroups();
    const groups = new Set([...world.kogenGroups, ...world.commandGroups]);
    assert.ok(groups.size, 'no Build command process group was recorded');
    assert.ok(![...groups].some(group => world.processGroupAlive(group)), 'a process of the Build command process group is still running');
    return;
  }
  if (label === 'no process started by the Build\'s commands is running') {
    await world.verifyWatchedCommandGroups();
    assert.ok(world.commandWatchers.some(watcher => watcher.watched), 'no Build command process was watched');
    assert.ok(world.commandGroups.size, 'no Build command process group was recorded');
    assert.ok(![...world.commandGroups].some(group => world.processGroupAlive(group)), 'a process started by the Build commands is still running');
    return;
  }
  if (label.startsWith('no request contains ')) {
    assert.ok(!world.server.requests.some(request => request.text.includes(args[0])));
    return;
  }
  if (label.startsWith('the fake ChatGPT server received ')) {
    const expected = label === 'the fake ChatGPT server received 0 requests' ? 0 : Number(args[0]);
    assert.equal(world.server.requests.length, expected);
    return;
  }
  if (label.startsWith('the authorization server received ')) {
    assert.equal(world.server.refreshRequests, Number(args[0]));
    return;
  }
  if (label === 'the saved refresh token is the rotated one') {
    assert.equal(currentCredential(world)?.refresh_token, ROTATED_REFRESH_TOKEN);
    return;
  }
  if (label.startsWith('request ')) return requestAssertions(world, label, args);
  if (label === 'no builder request was sent after review began') {
    const first = world.server.requests.find(request => request.kind === 'review');
    assert.ok(first, 'no review request was received');
    assert.ok(!world.server.requests.some(request => request.kind === 'build' && request.order > first.order), 'a new builder request followed review');
    return;
  }
  if (label.startsWith('the Build records ')) {
    const result = JSON.parse(fs.readFileSync(path.join(latestRunDir(world), 'result.json'), 'utf8'));
    assert.equal(result.reviews, Number(args[0]));
    assert.equal(result.passes, Number(args[1]));
    return;
  }
  if (label.startsWith('the review request')) return reviewAssertions(world, label, args);
  if (label.startsWith('the request after ')) return afterRequestAssertions(world, label, args);
  if (label.startsWith('the tool result for ')) return toolResultAssertions(world, label, args);
  if (label.startsWith('the tool calls ran in the order ')) {
    const names = world.server.toolResults.filter(item => item.kind === 'build').map(item =>
      ['shell', 'probe', 'read_file', 'write_file'].includes(item.name)
        ? `${item.name} ${toolArg(item)}`
        : item.name);
    assert.deepEqual(names, args[0].split(', '));
    return;
  }
  if (label.startsWith('the run log ')) return runLogAssertions(world, label, args);
  if (label === 'every tool call in the run log ran once') {
    const calls = runEvents(world).filter(event => event.event === 'tool_call');
    assert.ok(calls.length > 0, 'run log contains no tool_call events');
    const expected = world.server.responseItems.filter(item => item.kind === 'build').map(item => item.callId).sort();
    const actual = calls.map(event => event.call_id).sort();
    assert.deepEqual(actual, expected, 'run log tool_call ids do not match the calls emitted by the fake server');
    for (const id of expected) assert.equal(actual.filter(found => found === id).length, 1, `run log contains ${id} other than once`);
    return;
  }
  if (label.startsWith('the recorded acceptance environment has ')) {
    const env = JSON.parse(fs.readFileSync(projectFile(world, '.kogen/local/acceptance-env.json'), 'utf8'));
    if (label.includes('KOGEN_ACCEPTANCE_FEATURES')) assert.equal(env.features, args[0]);
    else {
      assert.ok(pathInside(projectFile(world, args[0]), path.resolve(env.report)), `${env.report} is outside ${args[0]}`);
      assert.ok(path.isAbsolute(env.report));
    }
    return;
  }
  if (label.startsWith('the probe ran outside')) {
    const logged = fs.existsSync(world.pythonCwdLog) ? fs.readFileSync(world.pythonCwdLog, 'utf8').trim().split(/\r?\n/) : [];
    const project = fs.realpathSync(world.project);
    const temp = fs.realpathSync(world.tempDir);
    assert.ok(logged.some(cwd => {
      // The wrapper records `pwd -P` while the scratch directory still exists.
      const realCwd = path.resolve(cwd);
      return realCwd !== project && pathInside(temp, realCwd) && path.basename(realCwd).startsWith('kogen-probe-');
    }), 'probe did not run from a scratch folder outside the project');
    return;
  }
  if (label === 'no probe scratch folder is left behind') {
    const leftovers = fs.readdirSync(fs.realpathSync(world.tempDir)).filter(name => name.startsWith('kogen-probe-'));
    assert.deepEqual(leftovers, []);
    return;
  }
  if (label === 'the deadline driver verified the five-minute policy and real timeout cleanup at 200 milliseconds') {
    assert.ok(world.probeDeadlineReceipt, 'the deadline driver was not run');
    const receipt = JSON.parse(fs.readFileSync(world.probeDeadlineReceipt, 'utf8'));
    assert.equal(receipt.original_timeout_ms, 300000);
    assert.equal(receipt.executed_timeout_ms, 200);
    assert.equal(receipt.command, 'sleep 600');
    assert.equal(receipt.timed_out, true);
    assert.equal(receipt.process_group_stopped, true);
    assert.equal(receipt.scratch_removed, true);
    assert.equal(receipt.core_exit, 0);
    assert.ok(Number.isInteger(receipt.pgid) && receipt.pgid > 1);
    assert.equal(world.processGroupAlive(receipt.pgid), false);
    assert.equal(fs.existsSync(receipt.scratch), false);
    await world.attach(JSON.stringify(receipt), 'application/json');
    return;
  }
  if (label === 'every stdout line so far is protocol output of kogen') {
    const lines = actual().stdout.split(/\r?\n/).filter(Boolean);
    assert.ok(lines.length, 'Kogen had not written a protocol line to stdout');
    assert.ok(lines.every(line => /^building [a-z0-9][a-z0-9-]*$/.test(line)), `stdout contained a line outside the Kogen result grammar: ${lines.join('\\n')}`);
    return;
  }
  if (label === 'the caller discards the edits listed in the last Build output') {
    const edited = world.lastBuildWithEdits?.stdout.match(/^  edited: (.+)$/m)?.[1];
    assert.ok(edited, 'the last Build output did not list its edits');
    const changed = edited.split(', ').map(value => value.trim()).filter(Boolean);
    const tracked = changed.filter(value => world.git(world.project, ['ls-files', '--error-unmatch', '--', value]).status === 0);
    const untracked = changed.filter(value => !tracked.includes(value));
    if (tracked.length) git(world, ['restore', '--staged', '--worktree', '--', ...tracked]);
    if (untracked.length) {
      const cleaned = world.git(world.project, ['clean', '-fd', '--', ...untracked]);
      assert.equal(cleaned.status, 0, cleaned.stderr || cleaned.stdout);
    }
    world.lastBuildWithEdits = null;
    return;
  }
  throw new Error(`step is registered but not implemented: ${label}`);
}

module.exports = { dispatch, plainPattern };

