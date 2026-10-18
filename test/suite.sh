#!/bin/sh
# The complete deterministic suite (REL-4). Build one current archive, prepare
# dependencies before workers start, then run independent layers concurrently.
# Every layer must pass. KOGEN_ARCHIVE selects an already-built archive.
set -eu
cd "$(dirname "$0")/.."
archive=${KOGEN_ARCHIVE:-$(sh packaging/package.sh)}
[ -f "$archive" ] || { echo "suite: archive not found: $archive" >&2; exit 1; }
KOGEN_ARCHIVE=$(cd "$(dirname "$archive")" && pwd)/$(basename "$archive")
export KOGEN_ARCHIVE
echo "suite: archive $KOGEN_ARCHIVE"
mix deps.get --only test >/dev/null

# Reuse only an install made for these exact manifests. Incomplete installs have
# no stamp and are retried; separate dependency directories never share writes.
install_node_deps() (
  cd "$1"
  stamp=node_modules/.kogen-suite-manifests
  expected=$(shasum -a 256 package.json package-lock.json)
  if [ ! -f "$stamp" ] || [ "$(cat "$stamp")" != "$expected" ] || [ ! -x "node_modules/.bin/$2" ]; then
    npm ci --silent --no-audit --no-fund
    printf '%s\n' "$expected" > "$stamp"
  fi
)
install_node_deps spec quint
install_node_deps test/acceptance cucumber-js

# Node is already required by the suite. Separate process groups let Ctrl-C stop
# each layer and its children, while per-layer logs avoid interleaved diagnostics.
node <<'JS'
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, execFileSync } = require('node:child_process');
const root = process.cwd();
const logs = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-suite-'));
const layers = [
  ['exunit', root, 'mix', ['test']],
  ['go', path.join(root, 'cli'), 'go', ['test', '-race', '-count=1', './...']],
  ['spec', path.join(root, 'spec'), 'sh', ['check.sh']],
  ['live-helper', root, 'sh', ['test/live/check-verify.sh']],
  ['acceptance', path.join(root, 'test/acceptance'), 'npm', ['test']],
];
const groups = new Set();
let interrupted = 0;
let stopping;
function signalAll(signal) {
  for (const pid of groups) {
    try { process.kill(-pid, signal); } catch (error) {
      if (error.code !== 'ESRCH') throw error;
    }
  }
}
function includeDetachedChildren() {
  const rows = execFileSync('ps', ['-axo', 'pid=,ppid=,pgid='], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 })
    .trim().split('\n').map(line => line.trim().split(/\s+/).map(Number));
  const descendants = new Set(groups);
  let previous;
  do {
    previous = descendants.size;
    for (const [pid, ppid] of rows) if (descendants.has(ppid)) descendants.add(pid);
  } while (descendants.size !== previous);
  for (const [pid, , pgid] of rows) if (descendants.has(pid)) groups.add(pgid);
}
for (const [signal, status] of [['SIGINT', 130], ['SIGTERM', 143], ['SIGHUP', 129]]) {
  process.on(signal, () => {
    if (interrupted) return;
    interrupted = status;
    // Acceptance commands can detach their own core groups. Capture only this
    // suite's descendants before signalling; never kill unrelated host processes.
    includeDetachedChildren();
    signalAll(signal);
    const deadline = Date.now() + 5000;
    stopping = new Promise(resolve => {
      const timer = setInterval(() => {
        const alive = [...groups].some(pid => {
          try { process.kill(-pid, 0); return true; } catch (error) {
            if (error.code !== 'ESRCH') throw error;
            return false;
          }
        });
        if (!alive || Date.now() >= deadline) {
          if (alive) signalAll('SIGKILL');
          clearInterval(timer);
          resolve();
        }
      }, 50);
    });
  });
}
async function run([name, cwd, executable, args]) {
  const started = Date.now();
  const log = path.join(logs, `${name}.log`);
  const fd = fs.openSync(log, 'w');
  const child = spawn(executable, args, { cwd, detached: true, stdio: ['ignore', fd, fd] });
  fs.closeSync(fd);
  if (child.pid) groups.add(child.pid);
  const status = await new Promise(resolve => {
    child.once('error', error => {
      fs.appendFileSync(log, `${error.message}\n`);
      resolve(1);
    });
    child.once('close', code => resolve(code === null ? 1 : code));
  });
  if (!interrupted) groups.delete(child.pid);
  console.log(`suite: ${name} ${status === 0 ? 'passed' : 'FAILED'} (${((Date.now() - started) / 1000).toFixed(1)}s)`);
  process.stdout.write(fs.readFileSync(log));
  return status;
}
Promise.all(layers.map(run)).then(async statuses => {
  if (stopping) await stopping;
  fs.rmSync(logs, { recursive: true, force: true });
  process.exitCode = interrupted || (statuses.some(status => status !== 0) ? 1 : 0);
  if (process.exitCode === 0) console.log('suite: all passed');
}).catch(error => {
  signalAll('SIGKILL');
  console.error(error);
  console.error(`suite: logs retained in ${logs}`);
  process.exitCode = 1;
});
JS
