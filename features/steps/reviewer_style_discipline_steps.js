const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { When, Then } = require('@cucumber/cucumber');
const ROOT = path.resolve(__dirname, '../..');

// Reuse the existing installed-release fixture and recording fake provider.
// Capture the request, never scrape the source heredoc or simulate model judgment.
const driver = String.raw`
ExUnit.start(autorun: false)
Code.require_file("test/support/integration_helpers.ex")
alias Kogen.Integration.{Helpers, FakeProvider}
suite = Helpers.setup_suite!()
try do
  script = [
    {:function, "write_file", %{"path" => "app.txt", "content" => "verified edit\n"}},
    {:function, "finish", %{"summary" => "The fixture edit is ready."}},
    {:function, "submit_review", %{"verdict" => "approve", "findings" => []}}
  ]
  c = Helpers.project!(suite, script)
  try do
    {output, status} = Helpers.run_kogen(c, ["intent", "build", "fixture"])
    reviews = FakeProvider.review_requests(c.server)
    if reviews == [], do: raise("no actual reviewer request: #{output}")
    request = hd(reviews).json
    material = request["input"] |> Enum.map_join("\n", &(&1["content"] || ""))
    {committed, git_status} = Helpers.git!(c, ["show", "HEAD:app.txt"])
    if git_status != 0, do: raise("cannot read committed fixture: #{committed}")
    IO.puts("STYLE_POLICY_RESULT=" <> JSON.encode!(%{
      "instructions" => request["instructions"],
      "material" => material,
      "build status" => status,
      "reviewer requests" => length(reviews),
      "committed builder contents" => String.trim_trailing(committed, "\n"),
      "reviewer response tool" => elem(List.last(script), 1)
    }))
  after
    Helpers.cleanup_case(c)
  end
finally = :unused
rescue
  error -> reraise error, __STACKTRACE__
after
  Helpers.cleanup_suite(suite)
end
ExUnit.run()
`;

function capture() {
  return new Promise((resolve, reject) => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'reviewer-style-policy-'));
    const file = path.join(dir, 'capture.exs');
    fs.writeFileSync(file, driver);
    // Do not allow an externally selected older archive to stand in for this source.
    const env = { ...process.env, ERL_FLAGS: process.env.ERL_FLAGS || '+S 2:2 +SDcpu 1 +SDio 1' };
    delete env.KOGEN_ARCHIVE;
    const child = spawn('mix', ['run', file], { cwd: ROOT, env, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    let timedOut = false;
    child.stdout.on('data', b => { output += b; });
    child.stderr.on('data', b => { output += b; });
    const timer = setTimeout(() => {
      timedOut = true;
      try { process.kill(-child.pid, 'SIGKILL'); } catch {}
    }, 240000);
    child.on('error', error => {
      clearTimeout(timer);
      fs.rmSync(dir, { recursive: true, force: true });
      reject(error);
    });
    child.on('close', code => {
      clearTimeout(timer);
      fs.rmSync(dir, { recursive: true, force: true });
      try {
        assert.equal(timedOut, false, output);
        assert.equal(code, 0, output);
        const lines = output.split('\n').filter(line => line.startsWith('STYLE_POLICY_RESULT='));
        assert.equal(lines.length, 1, output);
        resolve(JSON.parse(lines[0].slice('STYLE_POLICY_RESULT='.length)));
      } catch (error) { reject(error); }
    });
  });
}

const normalize = text => text.replace(/\s+/g, ' ').trim().toLowerCase();
When('I capture the installed reviewer style policy', { timeout: 250000 }, async function () {
  this.stylePolicy = await capture();
  const material = this.stylePolicy.material;
  const marker = '# Testing rules (docs/testing-rules.md)';
  const start = material.indexOf(marker);
  const end = material.indexOf('# Check results of the final pass', start);
  assert.ok(start >= 0 && end > start, 'installed testing rules missing from reviewer request');
  const installedTesting = material.slice(start + marker.length, end);
  const section = installedTesting.match(/## The reviewer\s+([\s\S]*?)(?=\n## |$)/);
  assert.ok(section, 'reviewer section missing from installed testing rules');
  const sourceTesting = fs.readFileSync(path.join(ROOT, 'docs/testing-rules.md'), 'utf8');
  assert.ok(installedTesting.includes(sourceTesting.trim()), 'installed testing rules differ from current source');
  const spec = fs.readFileSync(path.join(ROOT, 'spec/prose/06-reviewing.md'), 'utf8');
  const rev4 = spec.match(/\*\*REV-4[^\n]*[\s\S]*?(?=\n\*\*REV-5)/);
  assert.ok(rev4, 'maintained REV-4 missing');
  this.styleOwners = { instructions: this.stylePolicy.instructions, testing: section[1], spec: rev4[0] };
});

function assertContains(text, table, column) {
  const missing = table.hashes().map(row => row[column]).filter(value => !normalize(text).includes(normalize(value)));
  assert.deepEqual(missing, [], 'missing emitted policy text');
}
Then('the emitted reviewer instructions contain these paragraphs:', function (table) {
  assertContains(this.stylePolicy.instructions, table, 'paragraph');
});
Then('the emitted reviewer instructions retain these safeguards:', function (table) {
  assertContains(this.stylePolicy.instructions, table, 'text');
});
Then('none of these reviewer policy owners retain these permissions:', function (table) {
  const failures = table.hashes().filter(row => {
    assert.ok(Object.hasOwn(this.styleOwners, row.owner), row.owner);
    return normalize(this.styleOwners[row.owner]).includes(normalize(row.forbidden));
  });
  assert.deepEqual(failures, [], 'obsolete opportunistic cleanup permission');
});
Then('the maintained reviewer sections cover these policy terms:', function (table) {
  const missing = table.hashes().filter(row => {
    assert.ok(Object.hasOwn(this.styleOwners, row.owner), row.owner);
    return !new RegExp(row.pattern, 'i').test(normalize(this.styleOwners[row.owner]));
  });
  assert.deepEqual(missing, [], 'maintained policy guidance missing');
});
Then('the style-policy fixture observations are:', function (table) {
  for (const row of table.hashes()) {
    assert.ok(Object.hasOwn(this.stylePolicy, row.observation), row.observation);
    assert.equal(String(this.stylePolicy[row.observation]), row.expected, row.observation);
  }
});
