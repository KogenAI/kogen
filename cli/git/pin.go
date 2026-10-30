package git

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

// Pin is the Git execution state of a checkout that a later trusted Git command would obey: every
// file of the effective hooks directory and the effective values of the configuration keys that
// select an executable. It is collected and compared without running a hook or a configured
// program, and it keeps digests, never configuration values.
//
// A pin holds one view for the environment Kogen runs Git with and, when that environment overrides
// where Git reads its system and global configuration (GIT_CONFIG_GLOBAL, GIT_CONFIG_SYSTEM,
// GIT_CONFIG_NOSYSTEM), a second view of the same checkout read from Git's default locations: the
// files stay in place for any later Git command of the user.
type Pin struct{ views []*pinView }

type pinView struct {
	hooksDir string            // the effective hooks directory as Git names it, absolute
	hooksID  string            // identity of that directory: resolved path and mode, or "absent"
	hooks    map[string]string // slash-relative path under the hooks directory -> state
	config   map[string][]string
}

// configOverrides are the variables that move or hide Git's system and global configuration files.
var configOverrides = map[string]bool{"GIT_CONFIG_GLOBAL": true, "GIT_CONFIG_SYSTEM": true, "GIT_CONFIG_NOSYSTEM": true}

// defaultLocations is r reading configuration from Git's default locations, or nil when its
// environment does not override them.
func (r *Repo) defaultLocations() *Repo {
	base := r.Env
	if base == nil {
		base = os.Environ()
	}
	var kept []string
	for _, kv := range base {
		if k, _, _ := strings.Cut(kv, "="); !configOverrides[k] {
			kept = append(kept, kv)
		}
	}
	if len(kept) == len(base) {
		return nil
	}
	c := *r
	c.Env = kept
	return &c
}

// executableKeys are the exact configuration keys that select a program (lower-cased section and
// variable); executableVars are the variables of a subsection key, "<section>.<subsection>.<var>".
var (
	executableKeys = map[string]bool{
		"core.hookspath": true, "core.fsmonitor": true, "core.sshcommand": true, "core.gitproxy": true,
		"core.editor": true, "core.pager": true, "core.askpass": true, "sequence.editor": true,
		"credential.helper": true, "gpg.program": true, "gpg.ssh.defaultkeycommand": true,
		"diff.external": true, "interactive.difffilter": true, "uploadpack.packobjectshook": true,
		"web.browser": true,
	}
	executableVars = map[string][]string{
		"credential": {"helper"}, "gpg": {"program"}, "filter": {"clean", "smudge", "process"},
		"diff": {"command", "textconv"}, "merge": {"driver"}, "difftool": {"cmd", "path"},
		"mergetool": {"cmd", "path"}, "browser": {"cmd", "path"}, "man": {"cmd", "path"},
		"remote": {"uploadpack", "receivepack", "vcs"}, "trailer": {"cmd"}, "submodule": {"update"},
	}
	executableSections = []string{"alias", "pager"} // every key of these sections
	canonicalVars      = map[string]string{
		"hookspath": "hooksPath", "sshcommand": "sshCommand", "gitproxy": "gitProxy", "askpass": "askPass",
		"difffilter": "diffFilter", "defaultkeycommand": "defaultKeyCommand", "packobjectshook": "packObjectsHook",
	}
)

// selectsExecutable reports whether the lower-cased-section-and-variable key names a configuration
// that selects a program.
func selectsExecutable(key string) bool {
	if executableKeys[key] {
		return true
	}
	section, rest, ok := strings.Cut(key, ".")
	if !ok {
		return false
	}
	if slices.Contains(executableSections, section) {
		return true
	}
	i := strings.LastIndex(rest, ".")
	if i < 0 {
		return false
	}
	return slices.Contains(executableVars[section], rest[i+1:])
}

// displayKey is key in Git's documented spelling (core.hooksPath); Git reports variable names in
// lower case.
func displayKey(key string) string {
	i := strings.LastIndex(key, ".")
	if c, ok := canonicalVars[key[i+1:]]; ok {
		return key[:i+1] + c
	}
	return key
}

func digest(parts ...string) string {
	h := sha256.New()
	for _, p := range parts {
		fmt.Fprintf(h, "%d:%s", len(p), p)
	}
	return hex.EncodeToString(h.Sum(nil))
}

// TakePin collects the pin of the repository whose work tree is r.Dir. Any state it cannot read or
// resolve is an error, never an unchanged pin. Git runs only to report configuration and paths.
func (r *Repo) TakePin() (*Pin, error) {
	p := &Pin{}
	for _, view := range []*Repo{r, r.defaultLocations()} {
		if view == nil {
			continue
		}
		v, err := view.takeView()
		if err != nil {
			return nil, err
		}
		p.views = append(p.views, v)
	}
	return p, nil
}

func (r *Repo) takeView() (*pinView, error) {
	p := &pinView{hooks: map[string]string{}, config: map[string][]string{}}
	listing, err := r.ok(nil, "config", "--list", "--show-scope", "-z")
	if err != nil {
		return nil, fmt.Errorf("the effective Git configuration cannot be read: %w", err)
	}
	// Records are "scope NUL key [NL value] NUL".
	toks := strings.Split(listing, "\x00")
	if len(toks)%2 == 0 || toks[len(toks)-1] != "" {
		return nil, fmt.Errorf("the effective Git configuration listing is malformed")
	}
	for i := 0; i+1 < len(toks); i += 2 {
		scope, entry := toks[i], toks[i+1]
		key, value, _ := strings.Cut(entry, "\n")
		if scope == "command" || !selectsExecutable(key) {
			continue
		}
		p.config[key] = append(p.config[key], digest(scope, value))
	}
	rel, err := r.okTrim(nil, "rev-parse", "--git-path", "hooks")
	if err != nil {
		return nil, fmt.Errorf("the effective hooks directory cannot be resolved: %w", err)
	}
	if rel == "" {
		return nil, fmt.Errorf("the effective hooks directory cannot be resolved: empty path")
	}
	// Git reports the path relative to where it ran, which is the work tree root.
	p.hooksDir = rel
	if !filepath.IsAbs(rel) {
		p.hooksDir = filepath.Join(r.Dir, rel)
	}
	p.hooksDir = filepath.Clean(p.hooksDir)
	if err := p.pinHooks(); err != nil {
		return nil, err
	}
	return p, nil
}

// pinHooks records the hooks directory's identity and every entry below it without following a
// symlink inside it; a symlink is recorded with its text, its resolved path and what it resolves to.
func (p *pinView) pinHooks() error {
	_, err := os.Lstat(p.hooksDir)
	if err != nil {
		if os.IsNotExist(err) {
			p.hooksID = "absent"
			return nil
		}
		return fmt.Errorf("the hooks directory %s cannot be read: %w", p.hooksDir, err)
	}
	real, err := filepath.EvalSymlinks(p.hooksDir)
	if err != nil {
		return fmt.Errorf("the hooks directory %s cannot be resolved: %w", p.hooksDir, err)
	}
	rst, err := os.Stat(real)
	if err != nil {
		return fmt.Errorf("the hooks directory %s cannot be read: %w", p.hooksDir, err)
	}
	p.hooksID = digest(real, fmt.Sprintf("%o", uint32(rst.Mode())))
	if !rst.IsDir() {
		return nil
	}
	return filepath.WalkDir(real, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return fmt.Errorf("the hooks directory entry %s cannot be read: %w", path, err)
		}
		if path == real {
			return nil
		}
		rel, err := filepath.Rel(real, path)
		if err != nil {
			return err
		}
		state, err := entryState(path)
		if err != nil {
			return err
		}
		p.hooks[filepath.ToSlash(rel)] = state
		return nil
	})
}

// entryState describes one hooks directory entry: its mode and bytes, or for a symlink its text,
// its resolved path and the mode and bytes of what it resolves to.
func entryState(path string) (string, error) {
	st, err := os.Lstat(path)
	if err != nil {
		return "", fmt.Errorf("the hook %s cannot be read: %w", path, err)
	}
	mode := fmt.Sprintf("%o", uint32(st.Mode()))
	switch {
	case st.Mode()&fs.ModeSymlink != 0:
		text, err := os.Readlink(path)
		if err != nil {
			return "", fmt.Errorf("the hook symlink %s cannot be read: %w", path, err)
		}
		real, err := filepath.EvalSymlinks(path)
		if err != nil {
			return "", fmt.Errorf("the hook symlink %s cannot be resolved: %w", path, err)
		}
		target, err := contentState(real)
		if err != nil {
			return "", err
		}
		return digest(mode, text, real, target), nil
	default:
		content, err := contentState(path)
		if err != nil {
			return "", err
		}
		return digest(mode, content), nil
	}
}

// contentState is the mode of a file and, for a regular one, the digest of its bytes; other kinds
// (directories, pipes, sockets) are never opened.
func contentState(path string) (string, error) {
	st, err := os.Stat(path)
	if err != nil {
		return "", fmt.Errorf("the hook %s cannot be read: %w", path, err)
	}
	mode := fmt.Sprintf("%o", uint32(st.Mode()))
	if !st.Mode().IsRegular() {
		return mode, nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("the hook %s cannot be read: %w", path, err)
	}
	sum := sha256.Sum256(data)
	return mode + ":" + hex.EncodeToString(sum[:]), nil
}

// Changes names what differs between p and later: each changed configuration key (never its value),
// a changed hooks directory and, in the same directory, each added, removed or changed hook path,
// sorted. It is empty when nothing differs.
func (p *Pin) Changes(later *Pin) []string {
	if len(p.views) != len(later.views) {
		return []string{"Git configuration locations"}
	}
	seen := map[string]bool{}
	var names []string
	add := func(n string) {
		if !seen[n] {
			seen[n] = true
			names = append(names, n)
		}
	}
	for i, a := range p.views {
		b := later.views[i]
		for _, k := range keysOf(a.config, b.config) {
			if !slices.Equal(a.config[k], b.config[k]) {
				add(displayKey(k))
			}
		}
		if a.hooksDir != b.hooksDir || a.hooksID != b.hooksID {
			add("hooks directory " + b.hooksDir)
		}
		if a.hooksDir != b.hooksDir {
			// A different directory is the change; its files are not compared one by one.
			continue
		}
		for _, k := range keysOf(a.hooks, b.hooks) {
			if a.hooks[k] != b.hooks[k] {
				add("hook " + filepath.Join(b.hooksDir, filepath.FromSlash(k)))
			}
		}
	}
	slices.Sort(names)
	return names
}

func keysOf[V any](a, b map[string]V) []string {
	seen := map[string]bool{}
	var keys []string
	for _, m := range []map[string]V{a, b} {
		for k := range m {
			if !seen[k] {
				seen[k] = true
				keys = append(keys, k)
			}
		}
	}
	slices.Sort(keys)
	return keys
}
