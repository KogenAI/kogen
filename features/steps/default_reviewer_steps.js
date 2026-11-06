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
import ("encoding/json"; "os"; "path/filepath"; "github.com/KogenAI/kogen-coordinator/project")
func write(root, rel, text string) {
  path := filepath.Join(root, rel)
  if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil { panic(err) }
  if err := os.WriteFile(path, []byte(text), 0o644); err != nil { panic(err) }
}
func main() {
  roles := project.DefaultModels()
  if os.Args[1] != "builtin" {
    root, err := os.MkdirTemp("", "reviewer-lineup-")
    if err != nil { panic(err) }
    defer os.RemoveAll(root)
    write(root, project.ConfigPath, project.Template())
    if os.Args[1] == "explicit" { write(root, project.ModelsPath, "models:\\n  review: {provider: chatgpt, model: gpt-6.1-sol, effort: high}\\n") }
    c, err := project.LoadConfig(root)
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
