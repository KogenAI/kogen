'use strict';
// Local fakes of github.com and api.github.com for install-kogen.sh, reached through a curl
// wrapper on PATH that rewrites those two origins to 127.0.0.1 and refuses every other URL.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const { spawn, execFileSync } = require('node:child_process');

const RATE_LIMIT = JSON.stringify({ message: "API rate limit exceeded for 203.0.113.7. (But here's the good news: Authenticated requests get a higher rate limit. Check out the documentation for more details.)", documentation_url: 'https://docs.github.com/rest/overview/resources-in-the-rest-api#rate-limiting' });
const LATEST = '/KogenAI/kogen/releases/latest';
const API_LATEST = '/repos/KogenAI/kogen/releases/latest';

function platform() {
  const s = execFileSync('uname', ['-s'], { encoding: 'utf8' }).trim().toLowerCase();
  const m = execFileSync('uname', ['-m'], { encoding: 'utf8' }).trim();
  return `${s}-${{ aarch64: 'arm64', arm64: 'arm64', x86_64: 'x86_64', amd64: 'x86_64' }[m] || m}`;
}

function releaseFiles(dir, version) {
  const name = `kogen-${version}-${platform()}`;
  const src = path.join(dir, 'src', name);
  fs.mkdirSync(src, { recursive: true });
  fs.writeFileSync(path.join(src, 'install.sh'), [
    '#!/bin/sh', 'set -eu', '[ "$1" = --prefix ] || exit 2', 'mkdir -p "$2/bin"',
    `printf '#!/bin/sh\\necho "kogen ${version} (fake)"\\n' > "$2/bin/kogen"`, 'chmod +x "$2/bin/kogen"', '',
  ].join('\n'));
  const archive = path.join(dir, `${name}.tar.gz`);
  execFileSync('tar', ['-czf', archive, '-C', path.join(dir, 'src'), name]);
  const bytes = fs.readFileSync(archive);
  const sums = `${crypto.createHash('sha256').update(bytes).digest('hex')}  ${name}.tar.gz\n`;
  return { [`/KogenAI/kogen/releases/download/${version}/${name}.tar.gz`]: bytes, [`/KogenAI/kogen/releases/download/${version}/SHA256SUMS`]: Buffer.from(sums) };
}

function listen(handler) {
  return new Promise((resolve, reject) => {
    const server = http.createServer(handler);
    server.on('error', reject);
    server.listen(0, '127.0.0.1', () => resolve(server));
  });
}

function send(res, status, headers, body) {
  res.writeHead(status, { 'content-length': Buffer.byteLength(body), ...headers });
  res.end(body);
}

// github: {mode: 'redirect', version} or {mode: 'status', status}; api: {mode: 'tag', version} or {mode: 'status', status}
async function runInstaller(installer, github, api) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'k-install-latest-'));
  const requests = [];
  let gh = null;
  let ap = null;
  try {
    const files = github.mode === 'redirect' ? releaseFiles(path.join(dir, 'release'), github.version) : {};
    gh = await listen((req, res) => {
      const p = req.url.split('?')[0];
      requests.push({ host: 'github', method: req.method, path: p });
      if (p === LATEST && github.mode === 'redirect') return send(res, 302, { location: `http://127.0.0.1:${gh.address().port}/KogenAI/kogen/releases/tag/${github.version}` }, '');
      if (p === LATEST) return send(res, github.status, { 'content-type': 'text/plain' }, 'Service Unavailable\n');
      if (github.mode === 'redirect' && p === `/KogenAI/kogen/releases/tag/${github.version}`) return send(res, 200, { 'content-type': 'text/html' }, `<html><title>Release ${github.version}</title></html>\n`);
      if (files[p]) return send(res, 200, { 'content-type': 'application/octet-stream' }, files[p]);
      return send(res, 404, { 'content-type': 'text/plain' }, 'Not Found\n');
    });
    if (api.mode === 'tag') Object.assign(files, releaseFiles(path.join(dir, 'api-release'), api.version));
    ap = await listen((req, res) => {
      const p = req.url.split('?')[0];
      requests.push({ host: 'api', method: req.method, path: p });
      if (p === API_LATEST && api.mode === 'tag') {
        return send(res, 200, { 'content-type': 'application/json; charset=utf-8', 'x-ratelimit-limit': '60', 'x-ratelimit-remaining': '59' }, `${JSON.stringify({
          url: 'https://api.github.com/repos/KogenAI/kogen/releases/1',
          html_url: `https://github.com/KogenAI/kogen/releases/tag/${api.version}`,
          id: 1, tag_name: api.version, target_commitish: 'main', name: api.version, draft: false, prerelease: false,
        }, null, 2)}\n`);
      }
      if (p === API_LATEST) return send(res, api.status, { 'content-type': 'application/json; charset=utf-8', 'x-ratelimit-limit': '60', 'x-ratelimit-remaining': '0' }, RATE_LIMIT);
      return send(res, 404, { 'content-type': 'application/json; charset=utf-8' }, '{"message":"Not Found"}');
    });
    const realCurl = execFileSync('sh', ['-c', 'command -v curl'], { encoding: 'utf8' }).trim();
    const bin = path.join(dir, 'bin');
    fs.mkdirSync(bin);
    const g = `http://127.0.0.1:${gh.address().port}`;
    const a = `http://127.0.0.1:${ap.address().port}`;
    fs.writeFileSync(path.join(bin, 'curl'), [
      '#!/bin/sh', `real='${realCurl}'`, 'n=$#', 'for a do', '  case $a in',
      `    https://github.com/*) a="${g}/\${a#https://github.com/}" ;;`,
      `    https://api.github.com/*) a="${a}/\${a#https://api.github.com/}" ;;`,
      `    ${g}/*|${a}/*) ;;`,
      '    http://*|https://*) echo "fake curl: refusing to reach $a" >&2; exit 7 ;;',
      '  esac', '  set -- "$@" "$a"', 'done', 'shift "$n"', 'exec "$real" "$@"', '',
    ].join('\n'), { mode: 0o755 });
    const home = path.join(dir, 'home');
    const tmpdir = path.join(dir, 'tmp');
    fs.mkdirSync(home);
    fs.mkdirSync(tmpdir);
    const env = { ...process.env, HOME: home, TMPDIR: tmpdir, PATH: `${bin}${path.delimiter}${process.env.PATH || ''}`, NO_PROXY: '*', no_proxy: '*' };
    for (const k of ['http_proxy', 'HTTP_PROXY', 'https_proxy', 'HTTPS_PROXY', 'all_proxy', 'ALL_PROXY', 'CURL_HOME']) delete env[k];
    const result = await new Promise((resolve, reject) => {
      const child = spawn('sh', ['-s'], { cwd: dir, env, stdio: ['pipe', 'pipe', 'pipe'] });
      let output = '';
      const timer = setTimeout(() => child.kill('SIGKILL'), 60000);
      child.stdout.on('data', b => { output += b; });
      child.stderr.on('data', b => { output += b; });
      child.on('error', reject);
      child.on('close', (code, signal) => { clearTimeout(timer); resolve({ code, signal, output }); });
      child.stdin.end(fs.readFileSync(installer));
    });
    return { ...result, requests, installed: fs.existsSync(path.join(home, '.local/bin/kogen')), platform: platform() };
  } finally {
    if (gh) gh.close();
    if (ap) ap.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

function describe(r) {
  return `\ninstaller exit ${r.code}${r.signal ? ` (signal ${r.signal})` : ''}; requests ${JSON.stringify(r.requests.map(q => `${q.host} ${q.method} ${q.path}`))}; output:\n${r.output}`;
}
const checks = {
  installed(r, version) {
    assert.equal(r.code, 0, `the installer should exit 0${describe(r)}`);
    assert.ok(r.output.split('\n').includes(`kogen ${version} (fake)`), `the installer should end by running the installed kogen ${version}${describe(r)}`);
    assert.ok(r.installed, `no kogen in $HOME/.local/bin${describe(r)}`);
  },
  latestAsked(r, n) {
    const got = r.requests.filter(q => q.host === 'github' && q.path === LATEST).length;
    assert.equal(got, n, `github.com${LATEST} was asked ${got} time(s), expected ${n}${describe(r)}`);
  },
  apiAsked(r, n) {
    const got = r.requests.filter(q => q.host === 'api').length;
    assert.equal(got, n, `the GitHub API was asked ${got} time(s), expected ${n}${describe(r)}`);
  },
  downloads(r, version) {
    const got = r.requests.filter(q => q.host === 'github' && q.path.startsWith('/KogenAI/kogen/releases/download/')).map(q => q.path).sort();
    const want = version ? [`/KogenAI/kogen/releases/download/${version}/SHA256SUMS`, `/KogenAI/kogen/releases/download/${version}/kogen-${version}-${r.platform}.tar.gz`].sort() : [];
    assert.deepEqual(got, want, `downloads ${JSON.stringify(got)}, expected ${JSON.stringify(want)}${describe(r)}`);
  },
  failed(r) {
    assert.equal(r.code, 1, `the installer should exit 1${describe(r)}`);
    assert.ok(!r.installed, `kogen was installed${describe(r)}`);
  },
  linesInOrder(r, expected) {
    const lines = r.output.split('\n');
    let at = 0;
    for (const want of expected) {
      const i = lines.indexOf(want, at);
      assert.ok(i >= 0, `missing output line (in this order) ${JSON.stringify(want)}${describe(r)}`);
      at = i + 1;
    }
  },
};

const BOTH_FAIL_LINES = [
  'install-kogen: could not find the latest release',
  'install-kogen: https://github.com/KogenAI/kogen/releases/latest answered HTTP 503',
  'install-kogen: https://api.github.com/repos/KogenAI/kogen/releases/latest answered HTTP 403',
  'install-kogen: to install a chosen release instead, pass its tag from https://github.com/KogenAI/kogen/releases with --version, for example: curl -fsSL https://github.com/KogenAI/kogen/releases/latest/download/install-kogen.sh | sh -s -- --version <tag>',
];

// Observer control: the same checks the scenarios run, against a given installer.
async function control(installer) {
  const v = 'v9.9.9-test';
  const cases = [
    ['redirect', { mode: 'redirect', version: v }, { mode: 'status', status: 403 }, r => { checks.installed(r, v); checks.latestAsked(r, 1); checks.apiAsked(r, 0); checks.downloads(r, v); }],
    ['fallback', { mode: 'status', status: 503 }, { mode: 'tag', version: v }, r => { checks.installed(r, v); checks.latestAsked(r, 1); checks.apiAsked(r, 1); checks.downloads(r, v); }],
    ['both-fail', { mode: 'status', status: 503 }, { mode: 'status', status: 403 }, r => { checks.failed(r); checks.downloads(r, null); checks.linesInOrder(r, BOTH_FAIL_LINES); checks.latestAsked(r, 1); checks.apiAsked(r, 1); }],
  ];
  const rejected = [];
  for (const [name, github, api, check] of cases) {
    const r = await runInstaller(installer, github, api);
    try { check(r); } catch (e) { rejected.push(`${name}: ${e.message.split('\n')[0]}`); }
  }
  return rejected;
}

if (require.main === module && process.argv[2] === 'control') {
  control(path.resolve(process.argv[3])).then(rejected => {
    process.stdout.write(rejected.length ? `rejected\n${rejected.join('\n')}\n` : 'accepted\n');
    process.exitCode = rejected.length ? 1 : 0;
  }, e => { process.stdout.write(`control error: ${e.message}\n`); process.exitCode = 2; });
}

module.exports = { runInstaller, checks };
