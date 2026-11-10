const fs = require('fs');
const os = require('os');
const path = require('path');
const cp = require('child_process');
const assert = require('assert');
const crypto = require('crypto');
function git(cwd, args) {
  const r = cp.spawnSync('git', args, {cwd, encoding:'utf8'});
  assert.strictEqual(r.status, 0, `git ${args.join(' ')}: ${r.stdout}${r.stderr}`);
  return r.stdout.trim();
}
function run(root, oldTag, tag, mode) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'brew-release-'));
  try {
    const tap = path.join(tmp,'tap'), remote = path.join(tmp,'remote.git'), assets = path.join(tmp,'release');
    fs.mkdirSync(tap); fs.mkdirSync(assets);
    git(tmp,['init','--bare',remote]); git(tap,['init','-b','main']);
    git(tap,['config','user.email','fixture@example.invalid']); git(tap,['config','user.name','Fixture']);
    fs.mkdirSync(path.join(tap,'Formula')); fs.mkdirSync(path.join(tap,'scripts'));
    const targets = ['linux-x86_64','darwin-arm64'];
    const base = 'https://github.com/KogenAI/kogen/releases/download/';
    const initial = 'class Kogen < Formula\n  version "'+oldTag.slice(1)+'"\n' + targets.map(t => `  url "${base}${oldTag}/kogen-${oldTag}-${t}.tar.gz"\n  sha256 "${'0'.repeat(64)}"`).join('\n')+'\nend\n';
    fs.writeFileSync(path.join(tap,'Formula/kogen.rb'), initial);
    fs.copyFileSync(path.join(__dirname,'update-formula.sh'), path.join(tap,'scripts/update-formula.sh'));
    if(mode === 'updater failure') fs.writeFileSync(path.join(tap,'scripts/update-formula.sh'), 'echo "tap updater refused" >&2\nexit 23\n');
    git(tap,['add','.']); git(tap,['commit','-m','Seed old tap']); git(tap,['remote','add','origin',remote]); git(tap,['push','-u','origin','main']);
    const sums = targets.map(t => {
      const name = `kogen-${tag}-${t}.tar.gz`, bytes = Buffer.from('archive '+tag+' '+t+'\n');
      fs.writeFileSync(path.join(assets,name),bytes);
      return crypto.createHash('sha256').update(bytes).digest('hex')+'  '+name;
    });
    fs.writeFileSync(path.join(assets,'SHA256SUMS'),sums.join('\n')+'\n');
    if(mode === 'checksum mismatch') fs.appendFileSync(path.join(assets,`kogen-${tag}-darwin-arm64.tar.gz`),'corrupt');
    let procedure = path.join(root,'packaging/update-homebrew.sh');
    if(!fs.existsSync(procedure)) { procedure=path.join(tmp,'noop.sh'); fs.writeFileSync(procedure,'exit 0\n'); }
    const r = cp.spawnSync('sh',[procedure,tag,tap,assets],{cwd:root,encoding:'utf8',timeout:20000});
    const formula = git(tmp,['--git-dir='+remote,'show','main:Formula/kogen.rb']);
    return {status:r.status, output:(r.stdout||'')+(r.stderr||''), formula, initial:initial.trim(), tag, targets, sums, base};
  } finally { fs.rmSync(tmp,{recursive:true,force:true}); }
}
function success(r) {
  assert.strictEqual(r.status,0,r.output);
  assert.ok(r.formula.includes(`version "${r.tag.slice(1)}"`),'version not updated');
  for(let i=0;i<r.targets.length;i++) {
    const url = `url "${r.base}${r.tag}/kogen-${r.tag}-${r.targets[i]}.tar.gz"`;
    assert.ok(r.formula.includes(url+'\n  sha256 "'+r.sums[i].slice(0,64)+'"'),'remote URL/checksum mismatch: '+r.targets[i]);
  }
}
function failure(r) {
  assert.ok(Number.isInteger(r.status) && r.status !== 0,'update must fail');
  assert.match(r.output,/homebrew|tap|checksum|SHA256/i,'failure must identify update/checksum');
  assert.strictEqual(r.formula,r.initial,'failed update must not publish changed formula');
}
function wiring(root) {
  const p = path.join(root,'.github/workflows/homebrew.yml');
  const s = fs.existsSync(p) ? fs.readFileSync(p,'utf8') : '';
  for(const x of ['published','HOMEBREW_TAP_TOKEN','KogenAI/homebrew-tap','packaging/update-homebrew.sh','SHA256SUMS','gh release download']) assert.ok(s.includes(x),'missing publication wiring: '+x);
  assert.ok(!/continue-on-error:\s*true|\|\|\s*true/.test(s),'update must not be ignored');
}
function docs(root, rows) {
  const s = fs.readFileSync(path.join(root,'README.md'),'utf8').split('## Install')[1].split('\n## ')[0];
  for(const [command, platforms] of rows) {
    assert.ok(s.includes(command),'missing Install command '+command);
    for(const p of platforms.split(', ')) assert.ok(s.includes(p),'missing Install platform '+p);
  }
}
module.exports = {run,success,failure,wiring,docs};
if(require.main === module) {
  const which = process.argv[2];
  const controls = JSON.parse(fs.readFileSync('.kogen/intents/release-updates-brew-formula-and-docs/controls.json','utf8'));
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(),'brew-observer-'));
  try {
    const files = {...controls.correct.files};
    if(which === 'bad') Object.assign(files,controls.wrong[0].files);
    for(const [p,s] of Object.entries(files)) { const f=path.join(tmp,p); fs.mkdirSync(path.dirname(f),{recursive:true}); fs.writeFileSync(f,s); }
    success(run(tmp,'v0.1.0-dev.47236bbb','v0.1.0-dev.40efd025','success'));
    if(which === 'good') { failure(run(tmp,'v0.1.0-dev.47236bbb','v0.1.0-dev.40efd025','updater failure')); failure(run(tmp,'v0.1.0-dev.47236bbb','v0.1.0-dev.40efd025','checksum mismatch')); wiring(tmp); }
    console.log('observer accepted');
  } catch(e) { console.log('observer rejected'); process.exitCode=1; }
  finally {fs.rmSync(tmp,{recursive:true,force:true});}
}
