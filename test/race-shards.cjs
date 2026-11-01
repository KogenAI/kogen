'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

function partition(names) {
  return names.slice().sort().map(name => ({ name, run: '^' + name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '$' }));
}

function command(file, args, options = {}) {
  const result = spawnSync(file, args, { encoding: 'utf8', ...options });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    if (result.stdout) process.stderr.write(result.stdout);
    if (result.stderr) process.stderr.write(result.stderr);
    throw new Error(`${file} ${args.join(' ')} failed (${result.signal || result.status})`);
  }
  if (result.stderr) process.stderr.write(result.stderr);
  return result.stdout;
}

function main(patterns) {
  const packages = command('go', ['list', '-race', '-f', '{{.ImportPath}}\t{{.Dir}}', ...(patterns.length ? patterns : ['./...'])]);
  const goroot = command('go', ['env', 'GOROOT']).trim();
  const env = { ...process.env, PATH: path.join(goroot, 'bin') + path.delimiter + process.env.PATH };
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-race-shards-'));
  try {
    for (const [index, line] of packages.trim().split('\n').filter(Boolean).entries()) {
      const [pkg, dir] = line.split('\t');
      const binary = path.join(temp, `package-${index}.test`);
      const output = command('go', ['test', '-c', '-race', '-o', binary, pkg]);
      if (output) process.stderr.write(output);
      if (!fs.existsSync(binary)) continue;
      const listed = command(binary, ['-test.list=^(Test|Example|Fuzz)'], { cwd: dir, env });
      const names = listed.split('\n').filter(line => /^(Test|Example|Fuzz)\S*$/.test(line));
      for (const shard of partition(names)) {
        const start = process.hrtime.bigint();
        const result = spawnSync(binary, [`-test.run=${shard.run}`, '-test.timeout=10m'], { cwd: dir, env, stdio: ['ignore', 'pipe', 'pipe'] });
        const elapsedSeconds = Number(process.hrtime.bigint() - start) / 1e9;
        if (result.stdout) process.stderr.write(result.stdout);
        if (result.stderr) process.stderr.write(result.stderr);
        const status = result.status === null ? 1 : result.status;
        console.log(JSON.stringify({ type: 'shard', package: pkg, tests: [shard.name], elapsedSeconds, status }));
        if (result.error || status !== 0) throw new Error(`shard ${pkg} ${shard.name} failed: ${result.error || result.signal || status}`);
      }
    }
  } finally {
    fs.rmSync(temp, { recursive: true, force: true });
  }
}

module.exports = { partition };
if (require.main === module) {
  try { main(process.argv.slice(2)); }
  catch (error) { console.error(error); process.exitCode = 1; }
}
