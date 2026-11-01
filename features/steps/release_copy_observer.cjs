const fs = require('node:fs');
const path = require('node:path');
function files(root) {
  const result = [];
  if (!fs.existsSync(root)) return result;
  for (const e of fs.readdirSync(root, { withFileTypes: true })) {
    const p = path.join(root, e.name);
    if (e.isDirectory()) result.push(...files(p));
    else result.push(p);
  }
  return result;
}
function observe(workspace, source) {
  const entries = files(workspace);
  const sourceCount = files(source).length;
  let fullCopies = 0;
  for (const p of entries.filter(p => path.basename(p) === 'TARGET')) {
    const dir = path.dirname(p);
    if (fs.existsSync(path.join(dir, 'install.sh')) && files(dir).length >= sourceCount * 0.9) fullCopies++;
  }
  return { entries, fullCopies };
}
function verdict(r, baseline) {
  return r.scenarios === 8 && r.passed === 8 && r.files > 0 && r.files < baseline && r.fullCopies === 0;
}
if (process.argv[2] === 'control') {
  const os = require('node:os');
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'copy-observer-'));
  try {
    const source = path.join(root, 'source');
    const workspace = path.join(root, 'workspace');
    fs.mkdirSync(source);
    fs.mkdirSync(workspace);
    fs.writeFileSync(path.join(source, 'TARGET'), 'fixture');
    fs.writeFileSync(path.join(source, 'install.sh'), 'fixture');
    fs.writeFileSync(path.join(workspace, 'payload'), 'real bytes');
    if (process.argv[3] === 'bad') fs.cpSync(source, path.join(workspace, 'copy'), { recursive: true });
    const observed = observe(workspace, source);
    const ok = verdict({ scenarios: 8, passed: 8, files: observed.entries.length, fullCopies: observed.fullCopies }, 100);
    console.log(ok ? 'accepted' : 'rejected');
    process.exitCode = ok ? 0 : 1;
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
} else if (process.env.KOGEN_RELEASE_COPY_REPORT) {
  const { AfterStep, AfterAll } = require(path.resolve('node_modules/@cucumber/cucumber'));
  const seen = new Set();
  let fullCopies = 0;
  AfterStep(function () {
    if (!this.workspace || !fs.existsSync(this.workspace)) return;
    const observed = observe(this.workspace, this.sharedSource);
    for (const p of observed.entries) seen.add(p);
    fullCopies += observed.fullCopies;
  });
  AfterAll(function () {
    fs.writeFileSync(process.env.KOGEN_RELEASE_COPY_REPORT, JSON.stringify({ files: seen.size, fullCopies }));
  });
}
module.exports = { files, verdict };
