'use strict';
// The historical C3 producer for the reopen-blocked-review retained-checkpoint cases.
//
// The cases need a real Kogen built from c3ee2a8e ("Stop verification at the first failed gate"). Its absolute path on the
// original machine is not available, so the exact producer sources are kept as a compressed, provenance-bound, test-only
// fixture (test/migration/fixtures/c3-producer/: the git-archive tarball and PROVENANCE.json with the commit, tree, archive
// digest, per-file digests and the original LICENSE/NOTICE inside). This module verifies that fixture, builds the release
// with the sources' own packaging/package.sh and toolchain pins (Elixir/Erlang/Go/Node; legacy fixtures only), and installs
// it into disposable storage. It needs no Git history and no operator-specific path, and the result is cached per run.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');

const FIXTURE = path.resolve(__dirname, '../../test/migration/fixtures/c3-producer');
const sha256 = bytes => crypto.createHash('sha256').update(bytes).digest('hex');

function exec(file, args, opts = {}) {
  return new Promise((resolve, reject) => {
    const p = spawn(file, args, { ...opts, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    p.stdout.on('data', b => { output += b; }); p.stderr.on('data', b => { output += b; });
    const timer = setTimeout(() => { try { process.kill(-p.pid, 'SIGKILL'); } catch {} }, opts.timeout || 1200000);
    p.on('error', e => { clearTimeout(timer); reject(e); });
    p.on('close', code => { clearTimeout(timer); resolve({ code, output }); });
  });
}
function walk(dir) { return fs.readdirSync(dir, { withFileTypes: true }).flatMap(e => e.isDirectory() ? walk(path.join(dir, e.name)) : [path.join(dir, e.name)]); }

// The original version block of packaging/package.sh: the release version comes from the Git HEAD of a checkout.
const VERSION_BLOCK = /^sources\(\) \{.*\}\nif git rev-parse --verify -q HEAD[\s\S]*?^fi\n/m;

let producer;
// Builds (once per run) and installs the producer; resolves to { bin, version, root, provenance, seconds }.
function localProducer(parentDir) {
  if (!producer) producer = build(parentDir);
  return producer;
}

async function build(parentDir) {
  const started = Date.now();
  const provenance = JSON.parse(fs.readFileSync(path.join(FIXTURE, 'PROVENANCE.json'), 'utf8'));
  const archive = path.join(FIXTURE, provenance.archive.file), bytes = fs.readFileSync(archive);
  assert.equal(sha256(bytes), provenance.archive.sha256, 'C3 producer archive digest differs from PROVENANCE.json');
  const root = fs.realpathSync(fs.mkdtempSync(path.join(parentDir || os.tmpdir(), 'kogen-c3-producer-')));
  const src = path.join(root, 'src'), prefix = path.join(root, 'prefix'), home = path.join(root, 'home');
  fs.mkdirSync(src); fs.mkdirSync(home);
  const untar = await exec('/usr/bin/tar', ['-xzf', archive, '-C', src]); assert.equal(untar.code, 0, untar.output);
  // Every extracted file is exactly the recorded one, and nothing else is present.
  const want = new Map(provenance.files.map(f => [f.path, f.sha256]));
  const have = walk(src).map(f => path.relative(src, f)).filter(f => f !== 'pax_global_header');
  assert.deepEqual(have.sort(), [...want.keys()].sort(), 'C3 producer archive file list differs from PROVENANCE.json');
  for (const f of have) assert.equal(sha256(fs.readFileSync(path.join(src, f))), want.get(f), `C3 producer file digest differs: ${f}`);

  // Only the version block of a copy of the original package.sh changes: there is no Git history to read it from, so the genuine values are set.
  const script = path.join(src, 'packaging/package.sh'), original = fs.readFileSync(script, 'utf8');
  assert.match(original, VERSION_BLOCK, 'unexpected version block in the C3 producer packaging/package.sh');
  const { version, versionLine } = provenance.source;
  fs.writeFileSync(script, original.replace(VERSION_BLOCK, () => `version=${JSON.stringify(version)}\nline=${JSON.stringify(versionLine)}\n`));

  // The sources' own toolchain pins, through mise when it is installed, otherwise the tools already on PATH.
  const pins = fs.readFileSync(path.join(src, '.tool-versions'), 'utf8').split('\n').map(l => l.replace(/#.*/, '').trim().split(/\s+/)).filter(p => p.length === 2 && ['elixir', 'erlang', 'go', 'nodejs'].includes(p[0]));
  const mise = (process.env.PATH || '').split(path.delimiter).concat(['/opt/homebrew/bin', '/usr/local/bin']).map(d => path.join(d, 'mise')).find(p => fs.existsSync(p));
  const prefixCmd = mise ? [mise, 'exec', ...pins.map(([tool, v]) => `${tool}@${v}`), '--'] : [];
  const env = { ...process.env, HOME: home, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: path.join(home, '.gitconfig') };
  // The caller's real HOME carries the mise and npm state; keep those readable without touching them.
  if (mise) { env.MISE_DATA_DIR = process.env.MISE_DATA_DIR || path.join(os.homedir(), '.local/share/mise'); env.MISE_CONFIG_DIR = process.env.MISE_CONFIG_DIR || path.join(os.homedir(), '.config/mise'); env.MISE_CACHE_DIR = process.env.MISE_CACHE_DIR || path.join(os.homedir(), 'Library/Caches/mise'); }
  env.npm_config_cache = process.env.npm_config_cache || path.join(os.homedir(), '.npm');
  const cmd = args => (prefixCmd.length ? [...prefixCmd, ...args] : args);
  const sh = async (args, cwd) => { const [file, ...rest] = cmd(args); const r = await exec(file, rest, { cwd, env }); assert.equal(r.code, 0, `${args.join(' ')} failed:\n${r.output}`); return r.output; };

  const out = (await sh(['sh', 'packaging/package.sh'], src)).trim().split('\n').pop();
  assert.ok(out.startsWith(path.join(src, 'dist')) && fs.existsSync(out), `C3 producer package not built: ${out}`);
  const extract = path.join(root, 'extract'); fs.mkdirSync(extract);
  const unpack = await exec('/usr/bin/tar', ['-xzf', out, '-C', extract]); assert.equal(unpack.code, 0, unpack.output);
  const [name] = fs.readdirSync(extract);
  await sh(['sh', path.join(extract, name, 'install.sh'), '--prefix', prefix], extract);

  // The same test signing the candidate receives.
  const launcher = path.join(prefix, 'lib/kogen/bin/kogen');
  if (process.platform === 'darwin') {
    const sign = await exec('codesign', ['--force', '--sign', '-', launcher]); assert.equal(sign.code, 0, sign.output);
    const verify = await exec('codesign', ['--verify', launcher]); assert.equal(verify.code, 0, verify.output);
  }
  const bin = path.join(prefix, 'bin/kogen');
  const shown = await exec(bin, ['version'], { cwd: root, env: { PATH: process.env.PATH, HOME: home } });
  assert.equal(shown.code, 0, shown.output);
  assert.ok(shown.output.startsWith(`kogen ${version} `), `C3 producer reports an unexpected version: ${shown.output}`);
  fs.rmSync(path.join(src, 'dist'), { recursive: true, force: true });
  return { bin, version: shown.output.trim(), root, provenance, seconds: Math.round((Date.now() - started) / 1000) };
}

function removeProducer(result) { if (result) fs.rmSync(result.root, { recursive: true, force: true }); }
module.exports = { localProducer, removeProducer, FIXTURE };
