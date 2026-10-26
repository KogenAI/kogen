package claudecode

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// HookSubcommand is the hidden Kogen subcommand that production wires to RunHook:
// HookCommand = [os.Executable(), HookSubcommand].
const HookSubcommand = "__kogen_executor_hook"

// policy is the hook policy file Start writes into the task directory (0600). It is run
// custody read by the hook processes Claude Code starts; it holds no secrets.
type policy struct {
	// Root is the checkout's real path.
	Root string `json:"root"`
	// Protected are repository-relative protected paths (files or directories).
	Protected []string `json:"protected"`
	// Log is the hook log (JSON lines, append only) every hook writes its sentinel records to.
	Log string `json:"log"`
	// Nonce is per run; sentinel records carry it so a stale log cannot satisfy liveness.
	Nonce string `json:"nonce"`
}

// sentinel is one hook log record: proof the hook ran for a tool call, written BEFORE the hook
// answers.
type sentinel struct {
	Nonce     string `json:"nonce"`
	Hook      string `json:"hook"` // pretool | posttool
	ToolUseID string `json:"tool_use_id"`
	ToolName  string `json:"tool_name"`
	Path      string `json:"path,omitempty"`
	Decision  string `json:"decision"` // allow | deny | observed
	Reason    string `json:"reason,omitempty"`
	Time      string `json:"time"`
}

const maxHookInput = 64 << 20

// hookInput is the part of Claude Code's hook stdin JSON the hooks read.
type hookInput struct {
	CWD       string         `json:"cwd"`
	ToolName  string         `json:"tool_name"`
	ToolUseID string         `json:"tool_use_id"`
	ToolInput map[string]any `json:"tool_input"`
}

// RunHook is the entry point of the hook subcommand: args are everything after the subcommand
// name (`pretool --policy F` or `posttool --policy F`). It reads Claude Code's hook JSON from
// stdin and returns the process exit code.
//
// pretool denies Write/Edit/MultiEdit/NotebookEdit of a protected path, anything under a .git
// directory and anything resolving outside the checkout, answering with the documented
// PreToolUse deny JSON on stdout and exit 0 (the form observed to block under acceptEdits).
// Any hook failure (no policy, unreadable input, unwritable log) exits 2, the documented
// blocking code. The sentinel record is appended before the answer. posttool only records a
// Bash observation and always exits 0. Nothing but the deny JSON is ever printed to stdout.
func RunHook(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	if len(args) != 3 || args[1] != "--policy" || (args[0] != "pretool" && args[0] != "posttool") {
		fmt.Fprintln(stderr, "kogen executor hook: usage: (pretool|posttool) --policy FILE")
		return 2
	}
	mode := args[0]
	fail := func(msg string) int {
		fmt.Fprintln(stderr, "kogen executor hook: "+msg)
		if mode == "posttool" {
			return 0 // observation only: never blocks
		}
		return 2
	}
	var pol policy
	b, err := os.ReadFile(args[2])
	if err != nil {
		return fail("cannot read the policy")
	}
	if err := json.Unmarshal(b, &pol); err != nil || pol.Root == "" || pol.Log == "" {
		return fail("invalid policy")
	}
	raw, err := io.ReadAll(io.LimitReader(stdin, maxHookInput+1))
	if err != nil || len(raw) > maxHookInput {
		return fail("cannot read the hook input")
	}
	var in hookInput
	if err := json.Unmarshal(raw, &in); err != nil {
		return fail("invalid hook input")
	}
	rec := sentinel{Nonce: pol.Nonce, Hook: mode, ToolUseID: in.ToolUseID, ToolName: in.ToolName, Time: time.Now().UTC().Format(time.RFC3339Nano)}
	if mode == "posttool" {
		rec.Decision = "observed"
		if appendSentinel(pol.Log, rec) != nil {
			return fail("cannot write the hook log")
		}
		return 0
	}
	path := ""
	for _, k := range []string{"file_path", "notebook_path"} {
		if s, ok := in.ToolInput[k].(string); ok && s != "" {
			path = s
			break
		}
	}
	allow, reason, resolved := decide(pol, in.CWD, path)
	rec.Path, rec.Reason = resolved, reason
	rec.Decision = "allow"
	if !allow {
		rec.Decision = "deny"
	}
	if appendSentinel(pol.Log, rec) != nil {
		return fail("cannot write the hook log")
	}
	if allow {
		return 0
	}
	out, _ := json.Marshal(map[string]any{"hookSpecificOutput": map[string]any{
		"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "Kogen: " + reason,
	}})
	fmt.Fprintln(stdout, string(out))
	return 0
}

// appendSentinel appends one record (a single O_APPEND write) to the hook log, creating it 0600.
func appendSentinel(log string, rec sentinel) error {
	b, err := json.Marshal(rec)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(log, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o600)
	if err != nil {
		return err
	}
	_, werr := f.Write(append(b, '\n'))
	if cerr := f.Close(); werr == nil {
		werr = cerr
	}
	return werr
}

// decide is the pretool policy for one file path (empty: the tool call named none, which is
// refused). It returns whether to allow, the refusal reason and the resolved path for the log.
func decide(pol policy, cwd, raw string) (allow bool, reason, resolved string) {
	if raw == "" {
		return false, "the tool call names no file path", ""
	}
	root := resolveReal(pol.Root)
	base := cwd
	if base == "" || !filepath.IsAbs(base) {
		base = root
	}
	lexical := raw
	if !filepath.IsAbs(lexical) {
		lexical = filepath.Join(base, lexical)
	}
	lexical = filepath.Clean(lexical)
	resolved = resolveReal(lexical)
	targets := []string{lexical, resolved}
	if !within(root, resolved) {
		return false, "the path is outside the checkout", resolved
	}
	for _, t := range targets {
		if rel, ok := relUnder(root, t); ok && hasGitComponent(rel) {
			return false, "paths under .git are not editable", resolved
		}
	}
	for _, p := range pol.Protected {
		lp := filepath.Join(root, filepath.FromSlash(p))
		for _, pv := range []string{lp, resolveReal(lp)} {
			for _, t := range targets {
				if within(pv, t) {
					return false, "this is a protected path (" + filepath.ToSlash(p) + ")", resolved
				}
			}
		}
	}
	return true, "", resolved
}

// resolveReal is p with every symlink resolved, also for a path that does not exist yet (the
// longest existing prefix is resolved and the rest appended) and for a dangling final
// symlink (its target is followed, because a write creates the target).
func resolveReal(p string) string {
	for range 40 {
		p = filepath.Clean(p)
		existing, rest := p, ""
		for {
			if _, err := os.Lstat(existing); err == nil {
				break
			}
			parent := filepath.Dir(existing)
			if parent == existing {
				break
			}
			rest = filepath.Join(filepath.Base(existing), rest)
			existing = parent
		}
		r, err := filepath.EvalSymlinks(existing)
		if err == nil {
			return filepath.Join(r, rest)
		}
		fi, lerr := os.Lstat(existing)
		if lerr != nil || fi.Mode()&os.ModeSymlink == 0 {
			return p
		}
		t, rerr := os.Readlink(existing)
		if rerr != nil {
			return p
		}
		if !filepath.IsAbs(t) {
			t = filepath.Join(filepath.Dir(existing), t)
		}
		p = filepath.Join(t, rest)
	}
	return p
}

// within reports whether target is base or below it. Components compare case-insensitively:
// the usual macOS volume does not distinguish case, and over-denying a differently cased name
// on other systems is the safe side of a best-effort prevention.
func within(base, target string) bool {
	_, ok := relUnder(base, target)
	return ok
}

func relUnder(base, target string) (string, bool) {
	b := splitPath(base)
	t := splitPath(target)
	if len(t) < len(b) {
		return "", false
	}
	for i := range b {
		if !strings.EqualFold(b[i], t[i]) {
			return "", false
		}
	}
	return strings.Join(t[len(b):], "/"), true
}

func splitPath(p string) []string {
	var out []string
	for _, c := range strings.Split(filepath.ToSlash(filepath.Clean(p)), "/") {
		if c != "" {
			out = append(out, c)
		}
	}
	return out
}

func hasGitComponent(rel string) bool {
	for _, c := range strings.Split(rel, "/") {
		if strings.EqualFold(c, ".git") {
			return true
		}
	}
	return false
}

// readSentinels returns the pretool records of the log for the nonce, keyed by tool_use_id.
func readSentinels(log, nonce string) (map[string]sentinel, error) {
	b, err := os.ReadFile(log)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return map[string]sentinel{}, nil
		}
		return nil, err
	}
	out := map[string]sentinel{}
	for _, line := range strings.Split(string(b), "\n") {
		if line == "" {
			continue
		}
		var r sentinel
		if json.Unmarshal([]byte(line), &r) != nil || r.Hook != "pretool" || r.Nonce != nonce || r.ToolUseID == "" {
			continue
		}
		out[r.ToolUseID] = r
	}
	return out, nil
}
