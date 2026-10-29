const { When, Then } = require('@cucumber/cucumber');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

When('I read reviewer defaults from {string}', function (source) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-default-reviewer-'));
  try {
    const file = path.join(dir, 'main.go');
    fs.writeFileSync(file, `package main
import ("encoding/json"; "os"; "kogen/project")
func main() {
  roles := project.DefaultModels()
  if os.Args[1] != "builtin" {
    text := project.Template()
    if os.Args[1] == "explicit" { text = "version: 1\\nmodels:\\n  review: {provider: chatgpt, model: gpt-6.1-sol, effort: high}\\n" }
    c, err := project.ParseConfig(text, "project.yaml")
    if err != nil { panic(err) }
    roles = c.Models
  }
  if err := json.NewEncoder(os.Stdout).Encode(roles); err != nil { panic(err) }
}
`);
    this.reviewerDefaults = JSON.parse(execFileSync('go', ['run', file, source], {
      cwd: path.resolve('cli'), encoding: 'utf8', timeout: 120000,
    }));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

Then('the reviewer defaults JSON is:', function (expected) {
  assert.deepEqual(this.reviewerDefaults, JSON.parse(expected));
});
