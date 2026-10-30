package shape

import (
 "encoding/json"
 "os"
 "path/filepath"
 "testing"

 "kogen/executor"
)

// Mounted through go -overlay; production bytes are not replaced. All writes are
// confined to newShpFx's disposable checkout/home and this test's temporary dirs.
func TestShapeHooksObservation(t *testing.T) {
 f := newShpFx(t)
 f.useExternalShape(6)
 mode := os.Getenv("KOGEN_HOOK_CASE")
 marker := filepath.Join(f.Aux, "hook-ran")
 hook := filepath.Join(f.Root, ".git", "hooks", "commit-msg")
 write := func(p, s string, perm os.FileMode) {
  t.Helper()
  if err := os.WriteFile(p, []byte(s), perm); err != nil { t.Fatal(err) }
  if err := os.Chmod(p, perm); err != nil { t.Fatal(err) }
 }
 script := "#!/bin/sh\nprintf ran >> '" + marker + "'\nexit 0\n"
 // The shared fixture deliberately uses a private hooksPath. Override it here
 // before Shape to exercise Git's ordinary default hooks directory.
 f.git("config", "--unset-all", "core.hooksPath")
 if err := os.MkdirAll(filepath.Dir(hook), 0700); err != nil { t.Fatal(err) }
 target := filepath.Join(t.TempDir(), "external-hook")
 write(target, script, 0755)
 if mode != "add" {
  if mode == "symlink-target" || mode == "symlink-path" || mode == "honest" {
   if err := os.Symlink(target, hook); err != nil { t.Fatal(err) }
  } else { write(hook, script, 0755) }
 }
 global := filepath.Join(f.Home, ".gitconfig")
 inc := filepath.Join(f.Home, "included.gitconfig")
 write(inc, "[core]\n sshCommand = ssh\n", 0600)
 write(global, "[include]\n path = " + inc + "\n", 0600)
 mutated := false
 x := &shapeExec{t: t, rounds: []func(int, string) (executor.RoundResult, error){
  func(n int, root string) (executor.RoundResult, error) {
   mutated = true
   switch mode {
   case "add": write(hook, script, 0755)
   case "remove": if err := os.Remove(hook); err != nil { t.Fatal(err) }
   case "modify": write(hook, script + "# changed\n", 0755)
   case "mode": if err := os.Chmod(hook, 0644); err != nil { t.Fatal(err) }
   case "symlink-target": write(target, script + "# changed target\n", 0755)
   case "symlink-path":
    other := filepath.Join(t.TempDir(), "other-hook")
    write(other, script, 0755)
    if err := os.Remove(hook); err != nil { t.Fatal(err) }
    if err := os.Symlink(other, hook); err != nil { t.Fatal(err) }
   case "hooks-path":
    dir := t.TempDir()
    write(filepath.Join(dir, "commit-msg"), script, 0755)
    f.git("config", "core.hooksPath", dir)
   case "fsmonitor":
    cmd := filepath.Join(f.Aux, "monitor")
    write(cmd, script, 0755)
    f.git("config", "core.fsmonitor", cmd)
   case "filter": f.git("config", "filter.audit.clean", "sh -c 'exit 0'")
   case "global-include": write(inc, "[core]\n sshCommand = changed-ssh\n", 0600)
   case "honest":
   default: t.Fatalf("unknown hook fixture mode %q", mode)
   }
   return result(shpFiles())(n, root)
  },
  result(map[string]any{"files": []any{map[string]any{"path": ".kogen/intents/is-even/acceptance.feature", "content": shpFeature}}}),
 }}
 exit, err := f.shapeWith(x, "Add calc.is_even(n).")
 text := ""
 if err != nil { text = err.Error() }
 _, markerErr := os.Stat(marker)
 out := map[string]any{"mode": mode, "round_reached": mutated, "exit": exit, "error": text, "published": f.exists(".kogen/intents/is-even/intent.md"), "hook_ran": markerErr == nil}
 raw, err := json.Marshal(out)
 if err != nil { t.Fatal(err) }
 if err := os.WriteFile(os.Getenv("KOGEN_HOOK_OUTPUT"), raw, 0600); err != nil { t.Fatal(err) }
}
