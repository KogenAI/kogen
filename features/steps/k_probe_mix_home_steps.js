'use strict';
// k-probe-mix-home: a Shape probe in an Elixir repository uses the caller's installed Mix toolchain and Hex package
// cache, Hex archive included, while it still sees no caller credential. The probe runs through the real
// verify.RunProbe (k_probe_mix_home_driver.go) from a caller session whose environment this file builds exactly.
// The Hex archive is copied from the Mix home of the machine running the suite; the Hex dependency is a local
// fixture package, already fetched, so nothing contacts hex.pm.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { Given, When, Then, After } = require('@cucumber/cucumber');
const { goDriver, MIN } = require('./go_driver_support');

const ROOT = path.resolve(__dirname, '../..');
const HOMES = {
  "MIX_HOME and HEX_HOME outside the caller's HOME": 'set',
  "the defaults ~/.mix and ~/.hex under the caller's HOME": 'default',
};

function work(world) {
  if (!world.kpmhDir) world.kpmhDir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'k-probe-mix-home-')));
  return world.kpmhDir;
}
function write(file, text) { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, text); }
function program(name) {
  const r = spawnSync('/bin/sh', ['-c', `command -v ${name}`], { encoding: 'utf8' });
  assert.ok(r.status === 0 && r.stdout.trim(), `${name} is not on PATH; this scenario needs Elixir and Erlang from .tool-versions`);
  return r.stdout.trim();
}
function camel(name) { return name.split('_').map(s => s[0].toUpperCase() + s.slice(1)).join(''); }
function files(dir, prefix = '') {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap(e => e.isDirectory()
    ? files(path.join(dir, e.name), `${prefix}${e.name}/`) : [`${prefix}${e.name}`]).sort();
}

After(function () { if (this.kpmhDir) fs.rmSync(this.kpmhDir, { recursive: true, force: true }); });

Given('a minimal Mix project whose Hex dependency {string} version {string} is already fetched', function (dep, version) {
  const project = path.join(work(this), 'project');
  const inner = 'a'.repeat(64), outer = 'b'.repeat(64);
  write(path.join(project, 'mix.exs'), `defmodule ProbeFixture.MixProject do\n  use Mix.Project\n\n  def project, do: [app: :probe_fixture, version: "0.1.0", deps: [{:${dep}, "${version}"}]]\nend\n`);
  write(path.join(project, 'lib/probe_fixture.ex'), `defmodule ProbeFixture do\n  def answer, do: ${camel(dep)}.answer()\nend\n`);
  write(path.join(project, 'mix.lock'), `%{\n  "${dep}": {:hex, :${dep}, "${version}", "${inner}", [:mix], [], "hexpm", "${outer}"},\n}\n`);
  const fetched = path.join(project, 'deps', dep);
  write(path.join(fetched, 'mix.exs'), `defmodule ${camel(dep)}.MixProject do\n  use Mix.Project\n\n  def project, do: [app: :${dep}, version: "${version}", deps: []]\nend\n`);
  write(path.join(fetched, 'lib', `${dep}.ex`), `defmodule ${camel(dep)} do\n  def answer, do: 42\nend\n`);
  // The .hex metadata Hex writes when it fetches a package, matching the lock entry above.
  const r = spawnSync(program('elixir'), ['-e',
    '[file, name, version, inner, outer] = System.argv(); File.write!(file, :erlang.term_to_binary({{:hex, 2, 0}, %{name: name, version: version, managers: [:mix], repo: "hexpm", inner_checksum: inner, outer_checksum: outer}}))',
    path.join(fetched, '.hex'), dep, version, inner, outer], { cwd: ROOT, encoding: 'utf8' });
  assert.equal(r.status, 0, `writing the fetched dependency's .hex failed:\n${r.stdout}${r.stderr}`);
  this.kpmhProject = project;
  this.kpmhDep = { dep, version };
});

Given('the caller\'s Mix and Hex homes are {string}, the Hex home holding the cached package, a registry cache and a hex.config with the saved key {string}', function (where, key) {
  const kind = HOMES[where];
  assert.ok(kind, `unknown caller homes ${JSON.stringify(where)}; known: ${Object.keys(HOMES).join(' | ')}`);
  const dir = work(this);
  const home = path.join(dir, 'caller-home');
  fs.mkdirSync(home, { recursive: true });
  const mixHome = kind === 'set' ? path.join(dir, 'caller-tools', 'mix') : path.join(home, '.mix');
  const hexHome = kind === 'set' ? path.join(dir, 'caller-tools', 'hex') : path.join(home, '.hex');
  const installed = path.join(process.env.MIX_HOME || path.join(os.homedir(), '.mix'), 'archives');
  const archives = fs.existsSync(installed) ? fs.readdirSync(installed).filter(n => n.startsWith('hex-')) : [];
  assert.ok(archives.length > 0, `no Hex archive is installed in ${installed}; run "mix local.hex --force" once on this machine`);
  fs.mkdirSync(path.join(mixHome, 'archives'), { recursive: true });
  for (const a of archives) fs.cpSync(path.join(installed, a), path.join(mixHome, 'archives', a), { recursive: true });
  const { dep, version } = this.kpmhDep;
  write(path.join(hexHome, 'packages', 'hexpm', `${dep}-${version}.tar`), 'kogen probe package fixture\n');
  write(path.join(hexHome, 'cache.bin'), 'kogen probe registry cache fixture\n');
  write(path.join(hexHome, 'hex.config'), `{api_key,<<"${key}">>}.\n`);
  const bins = ['mix', 'erl'].map(n => path.dirname(program(n)));
  this.kpmhEnv = [`PATH=${[...new Set(bins), process.env.PATH].join(':')}`, `HOME=${home}`,
    ...(kind === 'set' ? [`MIX_HOME=${mixHome}`, `HEX_HOME=${hexHome}`] : [])];
  this.kpmhHexHome = hexHome;
});

Given('the caller\'s environment also has {word} set to {string}', function (name, value) {
  this.kpmhEnv.push(`${name}=${value}`);
});

When('a Shape probe runs in the Mix project:', { timeout: 15 * MIN }, async function (command) {
  const envFile = path.join(work(this), 'caller-env.json');
  fs.writeFileSync(envFile, JSON.stringify(this.kpmhEnv));
  const driver = await goDriver('k-probe-mix-home', fs.readFileSync(path.join(__dirname, 'k_probe_mix_home_driver.go'), 'utf8'));
  const r = await driver([this.kpmhProject, envFile, command]);
  assert.equal(r.code, 0, `probe driver failed:\n${r.out}`);
  this.kpmhResult = JSON.parse(r.out.trim().split('\n').pop());
});

Then('the caller\'s Hex home still holds exactly:', function (list) {
  assert.equal(files(this.kpmhHexHome).join('\n'), list.trim());
});

Then('the Mix probe exits with status {int} and output exactly:', function (status, output) {
  const got = this.kpmhResult;
  assert.deepEqual({ status: got.status, timed_out: got.timed_out, output: got.output },
    { status, timed_out: false, output: `${output}\n` });
});
