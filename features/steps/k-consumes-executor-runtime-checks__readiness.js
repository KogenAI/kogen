'use strict';
// Runs TestClaudeChecks (cli/readiness) against the kogen-executor that cli/go.mod pins and against
// temporary copies of that module that add the runtime checks of kogen-executor's Build
// kogen-runs-unverified-claude-code-runtime (candidate 626c4649): outside a test origin
// (KOGEN_CLAUDE_CODE_URL set) the managed runtime must be the pinned size for the platform, and
// the file, its version folder and <home>/.kogen/claude-code must be owned by the current user and
// not writable by group or others. Two of the copies are also broken on purpose, so the test must
// still tell another version and a missing claude.ai sign-in apart:
//   checked       the runtime checks
//   versionblind  the runtime checks, and claudecode.Pinned accepts every version
//   signinblind   the runtime checks, and claudecode.Probe answers every `auth ...` with a
//                 claude.ai sign-in
// Each copy is used through GOFLAGS=-modfile=<tmp>/go.mod with a replace directive, so the
// checkout's cli/go.mod and cli/go.sum are never changed.
//
// Run directly (`node <this file> [--keep-test-origin]`) it prints one line per run and exits 0
// only when every run has its expected outcome: the observer controls of the Intent's Feasibility.
const assert = require('node:assert/strict');
const fs = require('node:fs'), os = require('node:os'), path = require('node:path'), cp = require('node:child_process');
const ROOT = process.cwd();
const CLI = path.join(ROOT, 'cli');
const P = 'k-consumes-executor-runtime-checks: ';
const MODULE = 'github.com/KogenAI/kogen-executor';
const TEST = 'TestClaudeChecks';
const TEST_ARGS = ['test', '-count=1', '-v', '-run', '^TestClaudeChecks$', './readiness/'];
const SUBTESTS = [
  'another_version_names_the_path_and_the_fix',
  'pinned_with_subscription_sign-in',
  'not_signed_in',
  'another_sign-in_route_is_no_subscription',
  'stored_token_replaces_sign-in',
  'not_installed_yet_is_no_problem_with_a_token_and_never_downloads',
  'not_installed_and_no_token',
];
const KINDS = ['pinned', 'checked', 'versionblind', 'signinblind'];
const LABELS = {
  pinned: 'pinned kogen-executor',
  checked: 'kogen-executor with the runtime checks',
  versionblind: 'runtime checks that accept every version',
  signinblind: 'runtime checks that report every runtime signed in',
};
// EXPECTED_FAILS is the exact list of subtests each kind must fail; [] means every subtest passes.
const EXPECTED_FAILS = {
  pinned: [],
  checked: [],
  versionblind: ['another_version_names_the_path_and_the_fix'],
  signinblind: ['not_signed_in', 'another_sign-in_route_is_no_subscription'],
};
const RUNTIME = path.join('executor', 'claudecode', 'runtime.go');
// ANCHOR ends runtimeUsable in the pinned executor/claudecode/runtime.go; CHECKS goes before it.
const ANCHOR = '\treturn true, nil\n}\n\n// ensureRuntime';
const CHECKS = `\tif want, ok := pinFor(runtime.GOOS, runtime.GOARCH); ok {
\t\tif _, seam := os.LookupEnv(SeamEnv); !seam && info.Size() != want.size {
\t\t\treturn false, unavailable(fmt.Sprintf("Kogen's Claude Code at %s is %d bytes, expected %d; remove %s and run again", p, info.Size(), want.size, RuntimeDir(home)))
\t\t}
\t}
\tfor _, q := range []string{p, RuntimeDir(home), Root(home)} {
\t\tst, err := os.Stat(q)
\t\tif err != nil {
\t\t\treturn false, unavailable("cannot inspect " + q + ": " + err.Error())
\t\t}
\t\tunsafe := ""
\t\tif sys, ok := st.Sys().(*syscall.Stat_t); ok && int(sys.Uid) != os.Getuid() {
\t\t\tunsafe = fmt.Sprintf("is owned by uid %d, not uid %d", sys.Uid, os.Getuid())
\t\t} else if st.Mode().Perm()&0o020 != 0 {
\t\t\tunsafe = "is writable by group"
\t\t} else if st.Mode().Perm()&0o002 != 0 {
\t\t\tunsafe = "is writable by others"
\t\t}
\t\tif unsafe != "" {
\t\t\treturn false, unavailable("Kogen's Claude Code at " + p + " is unsafe: " + q + " " + unsafe + "; remove " + RuntimeDir(home) + " and run again")
\t\t}
\t}
`;
// BREAKS are the extra source edits of the broken copies: [file, exact old text, new text].
const BREAKS = {
  checked: [],
  versionblind: [[RUNTIME, '\treturn len(f) > 0 && f[0] == Version\n', '\treturn len(f) >= 0\n']],
  signinblind: [[RUNTIME, 'func Probe(ctx context.Context, home string, args ...string) ([]byte, error) {\n',
    'func Probe(ctx context.Context, home string, args ...string) ([]byte, error) {\n\tif len(args) > 0 && args[0] == "auth" {\n\t\treturn []byte(`{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}`), nil\n\t}\n']],
};

function run(cmd, args, env, timeout) {
  const r = cp.spawnSync(cmd, args, {cwd: CLI, env, encoding: 'utf8', timeout, maxBuffer: 64 * 1024 * 1024});
  return {command: [cmd, ...args].join(' '), goflags: env.GOFLAGS || '', status: r.status, signal: r.signal, error: r.error ? String(r.error) : '', stdout: r.stdout || '', output: (r.stdout || '') + (r.stderr || '')};
}
// env is the caller's environment without the acceptance report variables, a Go workspace, Go
// flags or (unless keepOrigin) a test origin, so only the test itself can set one.
function env(keepOrigin, goflags) {
  const e = {...process.env, GOWORK: 'off'};
  for (const k of ['GOFLAGS', 'KOGEN_ACCEPTANCE_REPORT', 'KOGEN_ACCEPTANCE_FEATURES']) delete e[k];
  if (!keepOrigin) delete e.KOGEN_CLAUDE_CODE_URL;
  if (goflags) e.GOFLAGS = goflags;
  return e;
}
function edit(file, old, replacement, what) {
  const source = fs.readFileSync(file, 'utf8');
  assert.equal(source.split(old).length, 2, `${what}: ${file} does not contain exactly one ${JSON.stringify(old)}`);
  fs.writeFileSync(file, source.replace(old, () => replacement));
}
// modfile copies the pinned module into tmp/<kind>, adds the runtime checks and the kind's breaks,
// and writes tmp/<kind>.mod/go.mod (cli/go.mod with absolute replaces and a replace of the module
// by the copy) and its go.sum; it returns the go.mod path.
function modfile(tmp, dir, version, kind) {
  const copy = path.join(tmp, kind);
  for (const [cmd, args] of [['cp', ['-R', dir, copy]], ['chmod', ['-R', 'u+w', copy]]]) {
    const r = run(cmd, args, process.env, 60000);
    assert.equal(r.status, 0, `${r.command} exited ${r.status} ${r.error}: ${r.output}`);
  }
  const what = `${MODULE} ${version} (${kind})`;
  edit(path.join(copy, RUNTIME), ANCHOR, CHECKS + ANCHOR, what);
  for (const [file, old, replacement] of BREAKS[kind]) edit(path.join(copy, file), old, replacement, what);
  const mods = path.join(tmp, kind + '.mod');
  fs.mkdirSync(mods);
  const gomod = fs.readFileSync(path.join(CLI, 'go.mod'), 'utf8').replace(/=> \.\/(\S+)/g, (_, rel) => '=> ' + path.join(CLI, rel));
  fs.writeFileSync(path.join(mods, 'go.mod'), gomod + `\nreplace ${MODULE} => ${copy}\n`);
  fs.copyFileSync(path.join(CLI, 'go.sum'), path.join(mods, 'go.sum'));
  return path.join(mods, 'go.mod');
}
// outcome reads `go test -v` output: the subtests that passed and failed, in order.
function outcome(r) {
  const seen = re => [...r.output.matchAll(re)].map(m => m[1]);
  return {
    passed: seen(new RegExp(`^\\s*--- PASS: ${TEST}/(\\S+)`, 'gm')),
    failed: seen(new RegExp(`^\\s*--- FAIL: ${TEST}/(\\S+)`, 'gm')),
    skipped: seen(new RegExp(`^\\s*--- SKIP: ${TEST}/(\\S+)`, 'gm')),
  };
}
// verdict is "passed" when every subtest passed and the run exited 0, else what happened.
function verdict(r) {
  const o = outcome(r);
  if (r.status === 0 && o.failed.length === 0 && o.skipped.length === 0 && SUBTESTS.every(s => o.passed.includes(s))) return 'passed';
  if (o.failed.length > 0) return 'failed in ' + o.failed.join(', ');
  if (o.skipped.length > 0) return 'skipped ' + o.skipped.join(', ');
  const missing = SUBTESTS.filter(s => !o.passed.includes(s));
  return missing.length ? 'did not run ' + missing.join(', ') : `exited ${r.status}`;
}
function expected(kind) {
  return EXPECTED_FAILS[kind].length ? 'failed in ' + EXPECTED_FAILS[kind].join(', ') : 'passed';
}
// observe runs TestClaudeChecks against every kind.
function observe(keepOrigin) {
  const dl = run('go', ['mod', 'download', '-json', MODULE], env(false), 240000);
  assert.equal(dl.status, 0, `${dl.command} exited ${dl.status} ${dl.error}: ${dl.output}`);
  const mod = JSON.parse(dl.stdout);
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'runtime-checks-'));
  try {
    const out = {};
    for (const kind of KINDS) {
      const flags = kind === 'pinned' ? '' : '-modfile=' + modfile(tmp, mod.Dir, mod.Version, kind);
      const r = run('go', TEST_ARGS, env(keepOrigin, flags), 300000);
      r.verdict = verdict(r);
      out[kind] = r;
    }
    return out;
  } finally {
    fs.rmSync(tmp, {recursive: true, force: true});
  }
}
function describe(r) {
  const tail = r.output.length > 6000 ? '...' + r.output.slice(-6000) : r.output;
  return `\`${r.goflags ? 'GOFLAGS=' + r.goflags + ' ' : ''}${r.command}\` (in cli) exited ${r.status}${r.signal ? ' (signal ' + r.signal + ')' : ''}${r.error ? ' ' + r.error : ''}\n${tail}`;
}
function check(o, kind) {
  const r = o[kind];
  const want = expected(kind);
  assert.equal(r.verdict, want, `${TEST} against the ${LABELS[kind]}: expected "${want}" (subtests ${SUBTESTS.join(', ')}), but it ${r.verdict}. ${describe(r)}`);
}

if (require.main === module) {
  const o = observe(process.argv.includes('--keep-test-origin'));
  let all = true;
  for (const kind of KINDS) {
    all = all && o[kind].verdict === expected(kind);
    console.log(`${LABELS[kind]}: ${TEST} ${o[kind].verdict}`);
  }
  process.exitCode = all ? 0 : 1;
} else {
  const {When, Then} = require('@cucumber/cucumber');
  When(P + 'TestClaudeChecks runs against the pinned kogen-executor and against copies with the runtime checks', {timeout: 1500000}, function () { this.runtimeChecks = observe(false); });
  Then(P + 'every TestClaudeChecks subtest passes against the pinned kogen-executor', function () { check(this.runtimeChecks, 'pinned'); });
  Then(P + 'every TestClaudeChecks subtest passes against the kogen-executor with the runtime checks', function () { check(this.runtimeChecks, 'checked'); });
  Then(P + 'TestClaudeChecks fails only in the version subtest against runtime checks that accept every version', function () { check(this.runtimeChecks, 'versionblind'); });
  Then(P + 'TestClaudeChecks fails only in the two sign-in subtests against runtime checks that report every runtime signed in', function () { check(this.runtimeChecks, 'signinblind'); });
}
