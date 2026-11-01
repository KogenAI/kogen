'use strict';
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const { performance } = require('node:perf_hooks');
require('@cucumber/cucumber/lib/support_code_library_builder/index').default.reset(process.cwd(), () => 'fixture');
const { dispatch } = require('./support/handlers');

const step = (world, label, args = []) => dispatch(world, `^${label}$`, args);
async function child() {
  const proc = spawn(process.execPath, ['-e', "process.on('SIGINT',()=>{}); console.log('ready'); setInterval(()=>{},1000)"], { detached: true, stdio: ['ignore', 'pipe', 'ignore'] });
  await once(proc.stdout, 'data');
  return proc;
}
async function cleanup(proc) {
  if (proc.exitCode === null && proc.signalCode === null) { proc.kill('SIGKILL'); await once(proc, 'exit'); }
}
async function quick(world) {
  const start = performance.now();
  await step(world, 'the kogen command is still running');
  assert.ok(performance.now() - start < 1500, 'progress liveness retained the two-second pad');
}
async function main() {
  const proc = await child();
  const world = { currentProcess: { child: proc, code: null }, server: { requests: [{ text: 'Verification pass 25 is not green.' }] } };
  let server;
  try {
    await step(world, 'the fake ChatGPT server has sent the feedback of verification pass (\\d+)', [25]);
    await quick(world);
    let wrongReceived = false;
    server = http.createServer((req, res) => {
      if (req.url.startsWith('/api/accounts/authorize?')) { res.writeHead(302, { location: `http://127.0.0.1:${server.address().port}/callback?state=correct` }); res.end(); }
      else { wrongReceived = new URL(req.url, 'http://localhost').searchParams.get('state') === 'wrong-state'; res.end('ignored'); }
    });
    server.listen(0, '127.0.0.1'); await once(server, 'listening');
    world.currentProcess.stdout = `http://127.0.0.1:${server.address().port}/api/accounts/authorize?state=correct\n`;
    await step(world, 'the browser sends a redirect with the wrong state');
    assert.ok(wrongReceived);
    await quick(world);
    await cleanup(proc);
    await assert.rejects(step(world, 'the kogen command is still running'), /exited/);
  } finally { if (server) await new Promise(resolve => server.close(resolve)); await cleanup(proc); }

  for (const exitDuring of [false, true]) {
    const p = await child();
    const w = { currentProcess: { child: p }, activeCommandGroup: p.pid, processGroupAlive: group => { try { process.kill(-group, 0); return true; } catch { return false; } } };
    let timer;
    try {
      if (exitDuring) timer = setTimeout(() => p.kill('SIGKILL'), 300);
      const start = performance.now();
      await step(w, "the caller sends SIGINT to the process group of the Build's running command", ['SIGINT']);
      assert.ok(performance.now() - start >= 1900, 'negative observation interval missing');
      if (exitDuring) await assert.rejects(step(w, 'the kogen command is still running'), /exited/);
      else await step(w, 'the kogen command is still running');
    } finally { clearTimeout(timer); await cleanup(p); }
  }
  const note = fs.readFileSync(path.join(__dirname, '../../docs/k-acceptance-fixed-wait.md'), 'utf8');
  for (const side of ['baseline', 'candidate']) for (const run of [1, 2, 3]) for (const scenario of ['04-building', '08-chatgpt', '09-cli-and-process']) {
    const line = note.split('\n').find(line => line.startsWith(`| ${side} | ${run} | ${scenario} |`));
    assert.ok(line && /\| 0 \|\s*$/.test(line), `missing successful measurement: ${side} ${run} ${scenario}`);
  }
  console.log('fixed-wait regression passed');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
