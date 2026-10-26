const assert = require('node:assert/strict');
const { spawn, execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { World, setWorldConstructor, setDefaultTimeout } = require('@cucumber/cucumber');
const { FakeServers } = require('./fake-servers');

const REPO = path.resolve(__dirname, '../../..');
const ACCEPTANCE = path.resolve(__dirname, '..');
// The Node that runs the suite (24) and a Python 3.10+ for the fixtures.
const NODE24 = path.dirname(process.execPath);
const PYTHON_BIN = process.env.KOGEN_TEST_PYTHON_BIN || resolvePython();
// Kogen needs no Erlang or Elixir. Only the `ex-app` fixture project (an Elixir project that Kogen builds)
// needs Mix; npm installs in fixtures use the suite's own cache (STEPS.md).
const ELIXIR_DIRS = ['mix', 'erl'].map(name => findProgram(name)).filter(Boolean).map(p => path.dirname(p));
// Bound the threads of that fixture project's own Erlang VM, keeping an explicitly supplied setting.
const ERL_FLAGS = process.env.ERL_FLAGS ?? '+S 2:2 +SDcpu 1 +SDio 1';
const NPM_CACHE = process.env.npm_config_cache || path.join(os.homedir(), '.npm');
const COMMAND_GROUP_CAPTURE_MS = 10000;

function capture(file, args, options = {}) {
  try {
    const stdout = execFileSync(file, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], ...options });
    return { status: 0, stdout, stderr: '' };
  } catch (error) {
    return {
      status: Number.isInteger(error.status) ? error.status : 127,
      stdout: String(error.stdout || ''),
      stderr: String(error.stderr || error.message || ''),
    };
  }
}

// The python3 on PATH, resolved to the real executable so that a version manager's
// shim still works under the scenarios' isolated homes.
function resolvePython() {
  const program = findProgram('python3');
  if (!program) return 'python3 (not on PATH)';
  const resolved = capture(program, ['-c', 'import sys; print(sys.executable)'], { cwd: REPO });
  return resolved.status === 0 && resolved.stdout.trim() ? resolved.stdout.trim() : program;
}

function findProgram(name, searchPath = process.env.PATH || '') {
  for (const dir of searchPath.split(path.delimiter)) {
    const candidate = path.join(dir, name);
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      return candidate;
    } catch {}
  }
  return null;
}

function mkdirp(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function copyTree(from, to) {
  fs.cpSync(from, to, { recursive: true, dereference: false, preserveTimestamps: true });
}

function shQuote(value) {
  return `'${String(value).replaceAll("'", "'\\''")}'`;
}

function waitBounded(promise, timeoutMs) {
  let timer;
  return Promise.race([
    promise,
    new Promise(resolve => { timer = setTimeout(resolve, timeoutMs); }),
  ]).finally(() => clearTimeout(timer));
}

function splitCommand(command) {
  const result = [];
  let value = '';
  let quote = null;
  let escaped = false;
  for (const ch of command) {
    if (escaped) {
      value += ch;
      escaped = false;
    } else if (quote === '"' && ch === '\\') {
      escaped = true;
    } else if (quote && ch === quote) {
      quote = null;
    } else if (!quote && (ch === '"' || ch === "'")) {
      quote = ch;
    } else if (!quote && /\s/.test(ch)) {
      if (value !== '') result.push(value);
      value = '';
    } else {
      value += ch;
    }
  }
  if (value !== '') result.push(value);
  return result;
}

function commandToArgv(world, raw) {
  const expanded = raw.replaceAll('{home}', world.home);
  const args = splitCommand(expanded);
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--project' && args[i + 1]) args[i + 1] = world.resolveProjectOption(args[i + 1]);
    else if (args[i].startsWith('--project=')) args[i] = `--project=${world.resolveProjectOption(args[i].slice('--project='.length))}`;
  }
  return args;
}

class AcceptanceWorld extends World {
  constructor(options) {
    super(options);
    this.workspace = null;
    this.home = null;
    this.tempDir = null;
    this.project = null;
    this.projectFixture = null;
    this.projectFolders = new Map();
    this.emptyFolders = new Map();
    this.prefix = null;
    this.archiveDir = null;
    this.privateInstall = null;
    this.commandOverride = null;
    this.homeConfig = true;
    this.toolPath = null;
    this.fakeClaude = null;
    this.hiddenPrograms = new Set();
    this.extraEnv = {};
    this.nodePath = null;
    this.processLog = null;
    this.runningPidFile = null;
    this.commandWatchers = [];
    this.stateFile = null;
    this.lastResult = null;
    this.lastBuildId = null;
    this.lastProject = null;
    this.lastBuildWithEdits = null;
    this.headBeforeLastCommand = null;
    this.lastProjectHead = null;
    this.notedHashes = new Map();
    this.reviewCardHashes = new Map();
    this.processes = new Set();
    this.commandGroups = new Set();
    this.kogenGroups = new Set();
    this.pollTimers = new Set();
    this.requestText = null;
    this.server = null;
    this.gitPath = findProgram('git');
    this.actualPath = this.basePath();
  }

  basePath() {
    const pieces = [path.join(this.prefix || '', 'bin'), NODE24];
    if (this.wrapperDir) pieces.push(this.wrapperDir);
    pieces.push(path.dirname(PYTHON_BIN));
    if (this.projectFixture === 'ex-app') pieces.push(...ELIXIR_DIRS);
    if (this.toolPath) pieces.unshift(this.toolPath);
    if (this.fakeClaude) pieces.unshift(this.fakeClaude.binDir);
    if (this.gitPath) pieces.push(path.dirname(this.gitPath));
    pieces.push('/usr/bin', '/bin', '/usr/sbin', '/sbin');
    const hidden = this.hiddenPrograms || new Set();
    return pieces.filter((p, i) => p && pieces.indexOf(p) === i && ![...hidden].some(name => fs.existsSync(path.join(p, name)))).join(path.delimiter);
  }

  env(overrides = {}) {
    return {
      HOME: this.home,
      PATH: this.basePath(),
      TMPDIR: this.tempDir,
      ...(this.projectFixture === 'ex-app' ? { ERL_FLAGS } : {}),
      KOGEN_NO_BROWSER: '1',
      npm_config_cache: NPM_CACHE,
      npm_config_prefer_offline: 'true',
      KOGEN_PROVIDER_URL: this.server ? this.server.providerUrl : 'http://127.0.0.1:1',
      KOGEN_AUTH_URL: this.server ? this.server.authUrl : 'http://127.0.0.1:1',
      KOGEN_GIT_LOG: this.gitLog,
      KOGEN_PYTHON_CWD_LOG: this.pythonCwdLog,
      KOGEN_PROCESS_LOG: this.processLog,
      KOGEN_PROCESS_CAPTURE_DIR: this.captureDir,
      KOGEN_ACCEPTANCE_RUNNING_PID: this.runningPidFile,
      KOGEN_OBSERVE_PROCESS_ARGUMENTS: this.observeProcessArguments ? '1' : '0',
      ...(this.extraEnv || {}),
      ...overrides,
    };
  }

  async setup() {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-acceptance-'));
    this.workspace = fs.realpathSync(root);
    this.home = path.join(this.workspace, 'home');
    mkdirp(this.home);
    const tempDir = path.join(this.workspace, 'tmp');
    mkdirp(tempDir);
    this.tempDir = fs.realpathSync(tempDir);
    this.gitLog = path.join(this.workspace, 'git-invocations.log');
    this.pythonCwdLog = path.join(this.workspace, 'python-cwds.log');
    this.processLog = path.join(this.workspace, 'processes.tsv');
    this.captureDir = path.join(this.workspace, 'process-capture');
    mkdirp(this.captureDir);
    this.runningPidFile = path.join(this.workspace, 'acceptance-running.pid');
    this.wrapperDir = path.join(this.workspace, 'wrappers');
    mkdirp(this.wrapperDir);
    this.writeGitConfig();
    this.writeWrappers();
    this.actualPath = this.basePath();
    this.server = new FakeServers();
    this.server.commandObserver = command => this.watchCommandGroup(command);
    await this.server.start();
    this.processes = new Set();
    this.commandGroups = new Set();
    this.kogenGroups = new Set();
    this.commandWatchers = [];
    this.pollTimers = new Set();
    this.projectFolders = new Map();
    this.emptyFolders = new Map();
    this.project = null;
    this.archiveDir = null;
    this.privateInstall = null;
    this.commandOverride = null;
    this.toolPath = null;
    this.fakeClaude = null;
    this.hiddenPrograms = new Set();
    this.extraEnv = {};
    this.notedHashes = new Map();
    this.reviewCardHashes = new Map();
    this.lastResult = null;
    this.lastBuildId = null;
    this.lastBuildWithEdits = null;
    this.requestText = null;
    this.nodePath = null;
  }

  writeGitConfig() {
    fs.writeFileSync(path.join(this.home, '.gitconfig'), [
      '[user]',
      '\tname = Kogen Acceptance',
      '\temail = kogen@example.invalid',
      '[init]',
      '\tdefaultBranch = main',
      '',
    ].join('\n'), { mode: 0o600 });
    this.homeConfig = true;
  }

  writeWrappers() {
    const pgidHelper = path.join(this.wrapperDir, 'kogen-pgid');
    fs.writeFileSync(pgidHelper, `#!/bin/sh\nprintf '%d\\n' "$(/bin/ps -o pgid= -p "$$")"\n`);
    fs.chmodSync(pgidHelper, 0o755);
    if (this.gitPath) {
      const wrapper = path.join(this.wrapperDir, 'git');
      const capture = `if [ -n "$KOGEN_PROCESS_CAPTURE_DIR" ] && [ -e "$KOGEN_PROCESS_CAPTURE_DIR/git" ]; then\n  while [ ! -e "$KOGEN_PROCESS_CAPTURE_DIR/ack.$$" ]; do /bin/sleep 0.01; done\n  rm -f "$KOGEN_PROCESS_CAPTURE_DIR/ack.$$"\nfi\n`;
      fs.writeFileSync(wrapper, `#!/bin/sh\nprintf '%s\\n' "$*" >> "$KOGEN_GIT_LOG"\nif [ "$KOGEN_OBSERVE_PROCESS_ARGUMENTS" = 1 ] || [ -e "$KOGEN_PROCESS_CAPTURE_DIR/git" ]; then\n  pgid=$(kogen-pgid)\n  printf 'git\\t%s\\t%s\\t%s\\t%s\\n' "$$" "$PPID" "$pgid" "$*" >> "$KOGEN_PROCESS_LOG"\n${capture}fi\nexec ${shQuote(this.gitPath)} "$@"\n`);
      fs.chmodSync(wrapper, 0o755);
    }
    const targets = {
      python3: PYTHON_BIN,
      sleep: findProgram('sleep'),
      curl: findProgram('curl'),
    };
    for (const [name, target] of Object.entries(targets)) {
      if (!target) continue;
      const wrapper = path.join(this.wrapperDir, name);
      const extra = name === 'python3' ? `printf '%s\\n' "$(pwd -P)" >> "$KOGEN_PYTHON_CWD_LOG"\n`
        : name === 'curl' ? `if [ -n "$KOGEN_TEST_NODE_DISTRIBUTION_URL" ] && [ "$#" = 2 ] && [ "$1" = -fsSL ]; then
  case "$2" in
    https://nodejs.org/dist/*) set -- "$1" "$KOGEN_TEST_NODE_DISTRIBUTION_URL/\${2#https://nodejs.org/dist/}" ;;
  esac
fi\n` : '';
      const capture = `if [ -n "$KOGEN_PROCESS_CAPTURE_DIR" ] && [ -e "$KOGEN_PROCESS_CAPTURE_DIR/${name}" ]; then\n  while [ ! -e "$KOGEN_PROCESS_CAPTURE_DIR/ack.$$" ]; do /bin/sleep 0.01; done\n  rm -f "$KOGEN_PROCESS_CAPTURE_DIR/ack.$$"\nfi\n`;
      fs.writeFileSync(wrapper, `#!/bin/sh\n${extra}if [ "$KOGEN_OBSERVE_PROCESS_ARGUMENTS" = 1 ] || [ -e "$KOGEN_PROCESS_CAPTURE_DIR/${name}" ]; then\n  pgid=$(kogen-pgid)\n  printf '${name}\\t%s\\t%s\\t%s\\t%s\\n' "$$" "$PPID" "$pgid" "$*" >> "$KOGEN_PROCESS_LOG"\n${capture}fi\nexec ${shQuote(target)} "$@"\n`);
      fs.chmodSync(wrapper, 0o755);
    }
  }

  setIdentity(enabled) {
    if (enabled) {
      this.writeGitConfig();
      delete this.extraEnv.GIT_CONFIG_NOSYSTEM;
      return;
    }
    fs.rmSync(path.join(this.home, '.gitconfig'), { force: true });
    this.homeConfig = false;
    this.extraEnv.GIT_CONFIG_NOSYSTEM = '1';
  }

  resolveProjectOption(value) {
    if (path.isAbsolute(value)) return value;
    if (this.projectFolders.has(value)) return this.projectFolders.get(value);
    return path.resolve(this.project || this.workspace, value);
  }

  projectRoot() {
    return this.project || this.workspace;
  }

  async createProject(fixture, folder) {
    const root = folder ? path.join(this.workspace, folder) : path.join(this.workspace, 'project');
    mkdirp(path.dirname(root));
    if (fixture === 'empty-repo') {
      mkdirp(root);
      this.git(root, ['init', '-q', '--initial-branch', 'main']);
    } else {
      this.projectFixture = fixture;
      const src = path.join(ACCEPTANCE, 'fixtures/projects', fixture);
      assert.ok(fs.existsSync(src), `project fixture not found: ${fixture}`);
      copyTree(src, root);
      this.git(root, ['init', '-q', '--initial-branch', 'main']);
      this.git(root, ['add', '-A']);
      const commit = this.git(root, ['commit', '-q', '-m', 'Fixture baseline']);
      assert.equal(commit.status, 0, commit.stderr || commit.stdout);
    }
    this.project = fs.realpathSync(root);
    this.projectFolders.set(folder || 'project', this.project);
    this.lastProjectHead = this.head(this.project);
    return this.project;
  }

  git(root, args, extraEnv = {}) {
    return capture(this.gitPath, args, { cwd: root, env: { ...this.env(), ...extraEnv, PATH: this.basePath() } });
  }

  head(root = this.project) {
    if (!root) return null;
    const result = this.git(root, ['rev-parse', '--verify', '-q', 'HEAD']);
    return result.status === 0 ? result.stdout.trim() : null;
  }

  gitDir(root = this.project) {
    return this.git(root, ['rev-parse', '--absolute-git-dir']).stdout.trim();
  }

  kogenPath() {
    return this.commandOverride || path.join(this.prefix, 'bin', 'kogen');
  }

  async invoke(raw, { stdin, keepStdin = false, cwd, background = false, env = {}, executableOverride = null } = {}) {
    const args = commandToArgv(this, raw);
    if (args[0] === 'kogen') args[0] = this.kogenPath();
    const program = executableOverride || args.shift();
    const argv = executableOverride ? args : args;
    const runCwd = cwd || this.project || this.archiveDir || this.workspace;
    const targetRoot = this.projectForCommand(raw, runCwd);
    this.headBeforeLastCommand = this.head(targetRoot);
    this.lastProject = targetRoot;
    const processEnv = this.env(env);
    const child = spawn(program, argv, {
      cwd: runCwd,
      env: processEnv,
      detached: true,
      stdio: [stdin === undefined && !keepStdin ? 'ignore' : 'pipe', 'pipe', 'pipe'],
    });
    const record = {
      child, stdout: '', stderr: '', done: null, code: null, signal: null,
      raw, argv: [program, ...argv], env: processEnv, cwd: runCwd, targetRoot,
      processTexts: new Map(), processArguments: new Map(), processMonitor: null,
      isKogen: program === this.kogenPath(),
    };
    record.done = new Promise(resolve => {
      child.stdout.setEncoding('utf8');
      child.stderr.setEncoding('utf8');
      child.stdout.on('data', chunk => {
        record.stdout += chunk;
        this.parseBuildId(record.stdout);
      });
      child.stderr.on('data', chunk => { record.stderr += chunk; });
      child.on('error', error => {
        record.stderr += error.message;
        record.code = 127;
        resolve(record);
      });
      child.on('close', (code, sig) => {
        record.code = code === null ? 128 : code;
        record.signal = sig;
        if (this.observeProcessArguments && record.isKogen) this.pollProcessTree(record);
        this.stopProcessTreeMonitor(record);
        this.stopSupervisedGroupTracking(record);
        resolve(record);
      });
    });
    if (child.pid) this.processes.add(record);
    if (child.pid && record.isKogen) {
      this.kogenGroups.add(child.pid);
      if (this.observeProcessArguments) this.startProcessTreeMonitor(record);
      this.startSupervisedGroupTracking(record);
    }
    if (stdin !== undefined && child.stdin) {
      // A command that refuses before reading its input closes stdin early; that is not a failure.
      child.stdin.on('error', error => { if (error.code !== 'EPIPE') throw error; });
      child.stdin.write(stdin);
      child.stdin.end();
    }
    if (background) {
      this.currentProcess = record;
      return record;
    }
    await record.done;
    this.remember(record);
    return record;
  }

  projectForCommand(raw, cwd) {
    const hasProject = /(?:^|\s)--project(?:=|\s)/.test(raw);
    if (!hasProject) return this.project || cwd;
    const tokens = commandToArgv(this, raw);
    let chosen = null;
    for (let i = 0; i < tokens.length; i++) {
      if (tokens[i] === '--project' && tokens[i + 1]) chosen = tokens[++i];
      else if (tokens[i].startsWith('--project=')) chosen = tokens[i].slice('--project='.length);
    }
    return chosen ? path.resolve(chosen) : this.project || cwd;
  }

  remember(record) {
    this.lastResult = record;
    if (/^kogen\s+intent\s+build\b/.test(record.raw) && /^  edited: .+$/m.test(record.stdout)) this.lastBuildWithEdits = record;
    this.parseBuildId(record.stdout);
  }

  parseBuildId(stdout) {
    const match = stdout.match(/\(Build ([0-9a-f]{8})\)/) || stdout.match(/Build ([0-9a-f]{8})/);
    if (match) this.lastBuildId = match[1];
  }

  startProcessTreeMonitor(record) {
    const poll = () => {
      try { this.pollProcessTree(record); } catch (error) { record.processMonitorError = error; }
    };
    poll();
    record.processMonitor = setInterval(poll, 50);
    this.pollTimers.add(record.processMonitor);
  }

  stopProcessTreeMonitor(record) {
    if (!record.processMonitor) return;
    clearInterval(record.processMonitor);
    this.pollTimers.delete(record.processMonitor);
    record.processMonitor = null;
  }

  listHostProcesses() {
    if (process.platform === 'darwin') {
      // Every process with its environment can exceed the default 1 MiB buffer on a busy machine.
      const output = execFileSync('/bin/ps', ['eww', '-axo', 'pid,ppid,pgid,command'], { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });
      return output.split(/\r?\n/).flatMap(line => {
        const match = line.trim().match(/^(\d+)\s+(\d+)\s+(\d+)\s+(.*)$/);
        return match ? [{ pid: Number(match[1]), ppid: Number(match[2]), pgid: Number(match[3]), command: match[4], raw: match[4] }] : [];
      });
    }
    const rows = [];
    for (const name of fs.readdirSync('/proc')) {
      if (!/^\d+$/.test(name)) continue;
      const pid = Number(name);
      try {
        const stat = fs.readFileSync(`/proc/${name}/stat`, 'utf8');
        const tail = stat.slice(stat.lastIndexOf(')') + 2).trim().split(/\s+/);
        const ppid = Number(tail[1]);
        const pgid = Number(tail[2]);
        const cmdline = fs.readFileSync(`/proc/${name}/cmdline`).toString().replaceAll('\0', ' ');
        const environment = fs.readFileSync(`/proc/${name}/environ`).toString().replaceAll('\0', ' ');
        rows.push({ pid, ppid, pgid, command: cmdline, raw: `${cmdline} ${environment}` });
      } catch {}
    }
    return rows;
  }

  pollProcessTree(record) {
    if (!record.child.pid) return;
    let rows;
    try {
      rows = this.listHostProcesses();
    } catch (error) {
      if (error.code !== 'EPERM') throw error;
      record.processListingRestricted = true;
      rows = this.instrumentedProcessRows(record);
    }
    const byPid = new Map(rows.map(row => [row.pid, row]));
    const descendants = new Set([record.child.pid]);
    let advanced = true;
    while (advanced) {
      advanced = false;
      for (const row of rows) {
        if (!descendants.has(row.pid) && descendants.has(row.ppid)) {
          descendants.add(row.pid);
          advanced = true;
        }
      }
    }
    for (const pid of descendants) {
      const row = byPid.get(pid);
      if (!row) continue;
      if (!record.processTexts.has(pid)) record.processTexts.set(pid, new Set());
      record.processTexts.get(pid).add(row.raw);
      if (!record.processArguments.has(pid)) record.processArguments.set(pid, new Set());
      record.processArguments.get(pid).add(row.command);
    }
  }

  instrumentedProcessRows(record) {
    const rootPid = record.child.pid;
    const envText = Object.entries(record.env || {}).map(([name, value]) => `${name}=${value}`).join(' ');
    const rootCommand = (record.argv || []).map(value => String(value)).join(' ');
    const rows = [{ pid: rootPid, ppid: 0, pgid: rootPid, command: rootCommand, raw: `${rootCommand} ${envText}` }];
    const groups = new Set(this.commandGroups);
    for (const item of this.processLogRows()) {
      if (!groups.has(item.pgid)) continue;
      const command = `${item.name} ${item.args}`.trim();
      rows.push({ pid: item.pid, ppid: rootPid, pgid: item.pgid, command, raw: `${command} ${envText}` });
    }
    return rows;
  }

  async waitFor(record = this.currentProcess, timeoutMs = 30000) {
    assert.ok(record, 'no background command is running');
    let timer;
    const timed = await Promise.race([
      record.done.then(() => true),
      new Promise(resolve => { timer = setTimeout(() => resolve(false), timeoutMs); }),
    ]).finally(() => clearTimeout(timer));
    assert.ok(timed, `command did not finish within ${timeoutMs} ms`);
    this.remember(record);
    if (record === this.currentProcess) this.currentProcess = null;
    return record;
  }

  sendSignal(record, sig) {
    assert.ok(record && record.child.pid, 'no kogen command process is running');
    record.child.kill(sig);
  }

  processLogRows() {
    if (!this.processLog || !fs.existsSync(this.processLog)) return [];
    return fs.readFileSync(this.processLog, 'utf8').split(/\r?\n/).filter(Boolean).map(line => {
      const [name, pid, ppid, pgid, ...args] = line.split('\t');
      return { name, pid: Number(pid), ppid: Number(ppid), pgid: Number(pgid), args: args.join('\t') };
    }).filter(row => Number.isInteger(row.pid) && Number.isInteger(row.ppid) && Number.isInteger(row.pgid));
  }

  processGroupFor(pid, ppid, pgid) {
    if (Number.isInteger(Number(pgid)) && Number(pgid) > 1) return Number(pgid);
    for (const candidate of [Number(pid), Number(ppid)]) {
      if (!Number.isInteger(candidate) || candidate <= 1) continue;
      try {
        process.kill(-candidate, 0);
        return candidate;
      } catch (error) {
        if (error.code === 'EPERM') return candidate;
      }
    }
    return null;
  }

  processGroupAlive(group) {
    try {
      process.kill(-Number(group), 0);
      return true;
    } catch (error) {
      return error.code === 'EPERM';
    }
  }

  // Every command kogen runs is led by a `kogen __kogen_supervise` watchdog in a process group of
  // its own. Record those groups while a kogen command runs, so checks can observe that no command
  // outlives it.
  trackSupervisedGroups(record) {
    if (!record.child.pid) return;
    let output;
    try {
      output = execFileSync('/bin/ps', ['-axo', 'pid=,ppid=,pgid=,command='], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
    } catch { return; }
    const rows = [];
    for (const line of output.split('\n')) {
      const match = line.match(/^\s*(\d+)\s+(\d+)\s+(\d+)\s+(.*)$/);
      if (match) rows.push({ pid: Number(match[1]), ppid: Number(match[2]), pgid: Number(match[3]), command: match[4] });
    }
    const descendants = new Set([record.child.pid]);
    for (let advanced = true; advanced;) {
      advanced = false;
      for (const row of rows) {
        if (!descendants.has(row.pid) && descendants.has(row.ppid)) { descendants.add(row.pid); advanced = true; }
      }
    }
    for (const row of rows) {
      if (descendants.has(row.pid) && row.pgid > 1 && row.pgid !== record.child.pid && row.command.includes('__kogen_supervise')) {
        this.commandGroups.add(row.pgid);
      }
    }
  }

  trackKogenGroups() {
    for (const record of this.processes) {
      if (record.isKogen && record.code === null) this.trackSupervisedGroups(record);
    }
  }

  startSupervisedGroupTracking(record) {
    this.trackSupervisedGroups(record);
    record.groupTracker = setInterval(() => this.trackSupervisedGroups(record), 100);
    this.pollTimers.add(record.groupTracker);
  }

  stopSupervisedGroupTracking(record) {
    if (!record.groupTracker) return;
    clearInterval(record.groupTracker);
    this.pollTimers.delete(record.groupTracker);
    record.groupTracker = null;
  }

  trackProcessGroup(pid, ppid, pgid) {
    const group = this.processGroupFor(pid, ppid, pgid);
    if (group) {
      this.commandGroups.add(group);
      this.activeCommandGroup = group;
    }
    return group;
  }

  watchCommandGroup(command) {
    const offset = fs.existsSync(this.processLog) ? fs.statSync(this.processLog).size : 0;
    const watcher = { command, offset, group: null, done: null, names: [], startedAt: Date.now() };
    const normalized = command.replace(/'([^']*)'/g, '$1').replace(/"([^"]*)"/g, '$1');
    const watchedNames = ['python3', 'sleep', 'curl', 'git'];
    watcher.names = watchedNames.filter(name => new RegExp(`\\b${name}\\b`).test(normalized));
    watcher.watched = watcher.names.length > 0;
    for (const name of watcher.names) fs.writeFileSync(path.join(this.captureDir, name), '');
    watcher.done = watcher.watched
      ? this.captureCommandGroup(watcher)
      : Promise.resolve(null);
    this.commandWatchers.push(watcher);
  }

  async captureCommandGroup(watcher) {
    const normalized = watcher.command.replace(/'([^']*)'/g, '$1').replace(/"([^"]*)"/g, '$1');
    // Capture starts at the provider reply, before the real command is scheduled.
    while (Date.now() - watcher.startedAt < COMMAND_GROUP_CAPTURE_MS) {
      const rows = this.processLogRows();
      let offset = 0;
      for (const row of rows) {
        const line = `${row.name}\t${row.pid}\t${row.ppid}\t${row.pgid}\t${row.args}\n`;
        const lineOffset = offset;
        offset += Buffer.byteLength(line);
        if (offset <= watcher.offset || lineOffset < watcher.offset) continue;
        if (!new RegExp(`\\b${row.name}\\b`).test(normalized)) continue;
        if (row.args && !normalized.includes(`${row.name} ${row.args}`)) continue;
        const group = this.trackProcessGroup(row.pid, row.ppid, row.pgid);
        if (group && this.processGroupAlive(group)) {
          watcher.group = group;
          watcher.aliveAtCapture = true;
          for (const name of watcher.names) fs.rmSync(path.join(this.captureDir, name), { force: true });
          fs.writeFileSync(path.join(this.captureDir, `ack.${row.pid}`), '');
          return group;
        }
      }
      await new Promise(resolve => setTimeout(resolve, 10));
    }
    return null;
  }

  async waitForCommandGroup(command, timeoutMs = COMMAND_GROUP_CAPTURE_MS) {
    const watcher = [...this.commandWatchers].reverse().find(item => item.command === command);
    assert.ok(watcher, `no process watcher was registered for command: ${command}`);
    let timer;
    const group = await Promise.race([
      watcher.done,
      new Promise(resolve => { timer = setTimeout(() => resolve(null), timeoutMs); }),
    ]).finally(() => clearTimeout(timer));
    if (!group) assert.fail(`Build command process group was not recorded: ${command}; elapsed=${Date.now() - watcher.startedAt}ms, rows=${JSON.stringify(this.processLogRows())}`);
    assert.equal(watcher.aliveAtCapture, true, `Build command process group was not alive when captured: ${command}`);
    return group;
  }

  async verifyWatchedCommandGroups() {
    const watchers = this.commandWatchers.filter(watcher => watcher.watched);
    await Promise.all(watchers.map(watcher => watcher.done));
    for (const watcher of watchers) {
      if (!watcher.group) assert.fail(`Build command process group was not recorded: ${watcher.command}; elapsed=${Date.now() - watcher.startedAt}ms, rows=${JSON.stringify(this.processLogRows())}`);
      assert.equal(watcher.aliveAtCapture, true, `Build command process group was not alive when captured: ${watcher.command}`);
    }
  }

  async cleanup() {
    const server = this.server;
    for (const record of this.processes) {
      if (record.child.exitCode === null && record.child.signalCode === null) {
        try { process.kill(-record.child.pid, 'SIGKILL'); } catch {}
        try { record.child.kill('SIGKILL'); } catch {}
      }
    }
    for (const group of this.commandGroups) {
      try { process.kill(-Number(group), 'SIGKILL'); } catch {}
    }
    for (const group of this.kogenGroups) {
      try { process.kill(-Number(group), 'SIGKILL'); } catch {}
    }
    for (const timer of this.pollTimers) clearTimeout(timer);
    this.pollTimers.clear();
    await Promise.all(this.commandWatchers.map(watcher => watcher.done));
    await Promise.all([...this.processes].map(record => waitBounded(record.done, 1000)));
    for (const record of this.processes) {
      record.child.stdout?.destroy();
      record.child.stderr?.destroy();
      record.child.stdin?.destroy();
      record.stdout = '';
      record.stderr = '';
      record.processTexts.clear();
      record.processArguments.clear();
      record.env = null;
      record.argv = [];
    }
    if (server) await server.close();
    if (this.nodeDistribution) {
      const distribution = this.nodeDistribution.server;
      await new Promise(resolve => { distribution.close(resolve); distribution.closeAllConnections(); });
      this.nodeDistribution = null;
    }
    if (this.workspace) fs.rmSync(this.workspace, { recursive: true, force: true });
    if (server) server.dispose();
    this.server = null;
    this.processes.clear();
    this.commandGroups.clear();
    this.kogenGroups.clear();
    this.commandWatchers.length = 0;
    this.projectFolders.clear();
    this.emptyFolders.clear();
    this.notedHashes.clear();
    this.reviewCardHashes.clear();
    this.fileBaselines?.clear();
    this.currentProcess = null;
    this.multiResults = null;
    this.lastResult = null;
    this.lastBuildWithEdits = null;
    this.requestText = null;
    this.workspace = null;
    this.home = null;
    this.tempDir = null;
    this.project = null;
    this.projectFixture = null;
  }
}

setWorldConstructor(AcceptanceWorld);
setDefaultTimeout(15 * 60 * 1000);

module.exports = {
  AcceptanceWorld,
  REPO,
  ACCEPTANCE,
  NODE24,
  PYTHON_BIN,
  capture,
  findProgram,
  mkdirp,
  copyTree,
  splitCommand,
  commandToArgv,
};
