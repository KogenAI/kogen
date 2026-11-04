'use strict';
// Observer control for k-consumes-kogen__suites.js and k-consumes-kogen__inventory.js: a synthetic
// module with one dependency, a good consumes suite that must be accepted, and bad variants that
// each carry one defect and must each be rejected for that defect. Run it as
// `node features/steps/k-consumes-kogen__control.js good|bad`; loaded by Cucumber it defines nothing.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

if (require.main === module) {
  process.env.K_CONSUMES_KOGEN_CONTROL = '1';
  const { inventory, problems, judgeGoTest, goTestSuites } = require('./k-consumes-kogen__suites.js');

  const mode = process.argv[2];
  if (!['good', 'bad'].includes(mode)) throw new Error('use good or bad');

  const goodTest = [
    'package consumes',
    '',
    'import (',
    '\t"testing"',
    '',
    '\t"kogen-loop/sys"',
    ')',
    '',
    'func TestNewAndOut(t *testing.T) {',
    '\ts := sys.New(sys.Options{Cwd: t.TempDir()})',
    '\tif s.Out() != "out" {',
    '\t\tt.Fatal("Out")',
    '\t}',
    '}',
    '',
  ].join('\n');
  const goodReadme = '# kogen-loop\n\n`sys.New`, `sys.Options`, `sys.Options.Cwd`, `sys.Session.Out`\n';

  function fixture(dir, change) {
    const files = {
      'go.mod': 'module fixture\n\ngo 1.27\n\nrequire kogen-loop v0.0.0\n\nreplace kogen-loop => ./loop\n',
      'main.go': 'package main\n\nimport (\n\t"fmt"\n\n\t"kogen-loop/sys"\n)\n\nfunc main() {\n\ts := sys.New(sys.Options{Cwd: "."})\n\tfmt.Println(s.Out())\n}\n',
      'lib/lib.go': 'package lib\n\nfunc Help() {}\n',
      'loop/go.mod': 'module kogen-loop\n\ngo 1.27\n',
      'loop/sys/sys.go': 'package sys\n\ntype Options struct {\n\tCwd string\n\tEnv []string\n}\n\ntype Session struct{ o Options }\n\nfunc New(o Options) *Session { return &Session{o} }\n\nfunc (s *Session) Out() string { return "out" }\n\nfunc Unused() {}\n',
      'consumes/kogen-loop/README.md': goodReadme,
      'consumes/kogen-loop/loop_test.go': goodTest,
    };
    change(files);
    for (const [rel, body] of Object.entries(files)) {
      if (body === null) continue;
      fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true });
      fs.writeFileSync(path.join(dir, rel), body);
    }
  }

  function judge(dir) {
    const found = problems(inventory(dir));
    const { list, test, packages } = goTestSuites(dir, Object.keys(inventory(dir).suites).sort());
    if (list.status !== 0) found.push(`go list: ${list.stderr}`);
    found.push(...judgeGoTest(test.stdout, packages));
    return found;
  }

  const host = '/' + 'Users/someone/';
  const bad = {
    directories: f => { f['consumes/kogen-other/README.md'] = goodReadme; f['consumes/kogen-other/x_test.go'] = 'package consumes\n\nimport "testing"\n\nfunc TestX(t *testing.T) {}\n'; },
    coverage: f => { f['consumes/kogen-loop/loop_test.go'] = goodTest.replace('if s.Out() != "out" {\n\t\tt.Fatal("Out")\n\t}\n', '_ = s\n'); },
    readme: f => { f['consumes/kogen-loop/README.md'] = goodReadme.replace(', `sys.Options.Cwd`', ''); },
    extra: f => { f['consumes/kogen-loop/loop_test.go'] = goodTest.replace('\ts := sys.New', '\tsys.Unused()\n\ts := sys.New'); },
    'isolation import': f => { f['consumes/kogen-loop/loop_test.go'] = goodTest.replace('"kogen-loop/sys"\n', '"fixture/lib"\n\t"kogen-loop/sys"\n').replace('\ts := sys.New', '\tlib.Help()\n\ts := sys.New'); },
    'isolation skip': f => { f['consumes/kogen-loop/loop_test.go'] = goodTest.replace('\ts := sys.New', '\tif testing.Short() {\n\t\tt.Skip("short")\n\t}\n\ts := sys.New'); },
    'isolation constraint': f => { f['consumes/kogen-loop/loop_test.go'] = '//go:build !nothing\n\n' + goodTest; },
    'isolation host path': f => { f['consumes/kogen-loop/loop_test.go'] = goodTest.replace('t.TempDir()', `"${host}x"`); },
    'go test': f => { f['consumes/kogen-loop/loop_test.go'] = goodTest.replace('!= "out"', '!= "other"'); },
  };

  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'k-consumes-kogen-control-'));
  try {
    if (mode === 'good') {
      const dir = path.join(root, 'good');
      fixture(dir, () => {});
      const found = judge(dir);
      if (found.length) { console.log(`good fixture rejected:\n${found.join('\n')}`); process.exitCode = 2; }
      else console.log('consumes fixture accepted');
    } else {
      let all = true;
      for (const [kind, change] of Object.entries(bad)) {
        const dir = path.join(root, kind.replace(/ /g, '-'));
        fixture(dir, change);
        const prefix = kind.startsWith('isolation') ? 'isolation' : kind;
        const found = judge(dir);
        if (found.some(p => p.startsWith(`${prefix}: `))) console.log(`${kind} defect rejected`);
        else { all = false; console.log(`${kind} defect accepted: ${found.join(' | ')}`); }
      }
      process.exitCode = all ? 1 : 2;
    }
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}
