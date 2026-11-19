package claudecode

import (
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	executorhook "github.com/KogenAI/kogen-executor/executor/claudecode"
)

// HookSubcommand is the hidden Kogen subcommand that production wires to RunHook:
// HookCommand = [os.Executable(), HookSubcommand]. The hook itself is the adopted executor
// component's: the policy file written here is the one its hook reads, and a process of this
// program that runs the hook decides exactly as that component does.
const HookSubcommand = executorhook.HookSubcommand

// RunHook is the entry point of the hook subcommand (args after the subcommand name, Claude
// Code's hook JSON on stdin); it returns the process exit code.
func RunHook(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	return executorhook.RunHook(args, stdin, stdout, stderr)
}

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
	// ReadOnly denies every file-writing tool call (the Shape role may inspect the checkout
	// but never change it).
	ReadOnly bool `json:"read_only,omitempty"`
	// ArtifactDir is the executor artifact directory (resolved) when it is the checkout, inside
	// it or a parent of it. File tools may not write to it: it holds this policy and the hook log.
	ArtifactDir string `json:"artifact_dir,omitempty"`
	// ProtectedIDs are the identities of the protected regular files that existed when Start wrote
	// the policy, in walk order. The hook compares them with a call target that has several links.
	ProtectedIDs []fileID `json:"protected_ids,omitempty"`
}

// fileID is the (device, inode) identity of one protected regular file, naming the policy entry
// (the file itself, or the protected directory holding it).
type fileID struct {
	Entry string `json:"entry"`
	Dev   uint64 `json:"dev"`
	Ino   uint64 `json:"ino"`
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

// statID is the (device, inode) and link count of a file's metadata.
func statID(fi os.FileInfo) (dev, ino, nlink uint64, ok bool) {
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, 0, 0, false
	}
	return uint64(st.Dev), uint64(st.Ino), uint64(st.Nlink), true
}

// protectedIDs records the identity of every protected regular file that exists now: an entry
// that is a regular file (a symlinked entry is followed) gives one record, and a directory
// entry gives one record per regular file inside it (symlinks inside are not followed). Anything
// missing, of another type or unreadable is skipped.
func protectedIDs(root string, entries []string) []fileID {
	var out []fileID
	for _, e := range entries {
		p := filepath.Join(root, filepath.FromSlash(e))
		fi, err := os.Stat(p)
		if err != nil {
			continue
		}
		switch {
		case fi.Mode().IsRegular():
			if d, i, _, ok := statID(fi); ok {
				out = append(out, fileID{Entry: e, Dev: d, Ino: i})
			}
		case fi.IsDir():
			_ = filepath.WalkDir(resolveReal(p), func(_ string, de fs.DirEntry, err error) error {
				if err != nil || !de.Type().IsRegular() {
					return nil
				}
				info, err := de.Info()
				if err != nil {
					return nil
				}
				if d, i, _, ok := statID(info); ok {
					out = append(out, fileID{Entry: e, Dev: d, Ino: i})
				}
				return nil
			})
		}
	}
	return out
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

// within reports whether target is base or below it: some ancestor of target (or target itself)
// is the same file as base. Comparing file identities instead of names leaves case and Unicode
// normalization to the volume. Both paths must exist.
func within(base, target string) bool {
	b, err := os.Stat(base)
	if err != nil {
		return false
	}
	for p := filepath.Clean(target); ; p = filepath.Dir(p) {
		if t, err := os.Stat(p); err == nil && os.SameFile(b, t) {
			return true
		}
		if filepath.Dir(p) == p {
			return false
		}
	}
}

// sentinelLog tracks the append-only hook log for one round. A trailing partial
// record is held until its newline is written.
type sentinelLog struct {
	offset  int64
	partial []byte
	records map[string]sentinel
}

func (l *sentinelLog) read(log, nonce string) (map[string]sentinel, error) {
	f, err := os.Open(log)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return map[string]sentinel{}, nil
		}
		return nil, err
	}
	defer f.Close()
	if _, err = f.Seek(l.offset, io.SeekStart); err != nil {
		return nil, err
	}
	b, err := io.ReadAll(f)
	if err != nil {
		return nil, err
	}
	l.offset += int64(len(b))
	b = append(l.partial, b...)
	lines := strings.Split(string(b), "\n")
	l.partial = []byte(lines[len(lines)-1])
	if l.records == nil {
		l.records = map[string]sentinel{}
	}
	for _, line := range lines[:len(lines)-1] {
		if line == "" {
			continue
		}
		var r sentinel
		if json.Unmarshal([]byte(line), &r) != nil || r.Hook != "pretool" || r.Nonce != nonce || r.ToolUseID == "" {
			continue
		}
		l.records[r.ToolUseID] = r
	}
	return l.records, nil
}
