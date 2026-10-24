package git

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"

	"kogen/sys"
)

// Tree returns the id of the candidate (VER-10): every tracked file and every untracked
// file not ignored, with content and mode, except the excluded paths (other uncommitted
// Intents' folders). It is built in a private index seeded from start's tree, so the
// user's index is untouched and nothing staged before the Build slips in (GIT-4).
func (r *Repo) Tree(start string, excluded []string) (string, error) {
	if err := checkRev(start); err != nil {
		return "", err
	}
	index := sys.TmpPath("kogen-index")
	defer os.Remove(index)
	env := []string{"GIT_INDEX_FILE=" + index}
	if _, err := r.ok(env, "read-tree", start); err != nil {
		return "", err
	}
	add := []string{"add", "-A", "--", "."}
	for _, p := range excluded {
		add = append(add, ":(exclude,literal)"+p)
	}
	if _, err := r.ok(env, add...); err != nil {
		return "", err
	}
	return r.okTrim(env, "write-tree")
}

// Changed lists the paths that differ between two trees (or commits), without rename
// detection.
func (r *Repo) Changed(a, b string) ([]string, error) {
	if err := errors.Join(checkRev(a), checkRev(b)); err != nil {
		return nil, err
	}
	out, err := r.ok(nil, "diff", "--name-only", "-z", "--no-renames", a, b, "--")
	return splitNUL(out), err
}

// Diff is the unified diff between two trees limited to paths, taken literally. No paths
// is an empty diff; DiffAll is the whole diff.
func (r *Repo) Diff(a, b string, paths []string) (string, error) {
	if len(paths) == 0 {
		return "", nil
	}
	spec := []string{"--"}
	for _, p := range paths {
		spec = append(spec, ":(literal)"+p)
	}
	return r.diff(a, b, spec)
}

// DiffAll is the unified diff between two trees.
func (r *Repo) DiffAll(a, b string) (string, error) { return r.diff(a, b, nil) }

func (r *Repo) diff(a, b string, spec []string) (string, error) {
	if err := errors.Join(checkRev(a), checkRev(b)); err != nil {
		return "", err
	}
	args := append([]string{"diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", a, b}, spec...)
	if spec == nil {
		args = append(args, "--")
	}
	return r.ok(nil, args...)
}

// TreeEntry is one file of a tree listed with `ls-tree -r`.
type TreeEntry struct{ Mode, Type, Object, Path string }

// TreeEntries lists every file of a tree (gitlinks are entries of type "commit").
func (r *Repo) TreeEntries(tree string) ([]TreeEntry, error) {
	if err := checkRev(tree); err != nil {
		return nil, err
	}
	out, err := r.ok(nil, "ls-tree", "-r", "-z", tree)
	if err != nil {
		return nil, err
	}
	var entries []TreeEntry
	for _, rec := range splitNUL(out) {
		meta, path, ok := strings.Cut(rec, "\t")
		f := strings.Split(meta, " ")
		if !ok || len(f) != 3 {
			return nil, fmt.Errorf("git ls-tree: unexpected entry %q", rec)
		}
		entries = append(entries, TreeEntry{Mode: f[0], Type: f[1], Object: f[2], Path: path})
	}
	return entries, nil
}

// ---- cold materialization ----

// Input is what the verification directory holds at one candidate path: enough to tell,
// after commands ran, whether the input changed (kind, symlink target, executable bits,
// content digest).
type Input struct {
	Kind   string // "file", "symlink", "directory", "other" or "missing"
	Target string // symlink target
	Exec   uint32 // permission bits & 0o111 of a file
	Digest [sha256.Size]byte
}

// Materialized is a candidate tree written cold into a directory: its own new repository
// with the tree as HEAD, holding none of the user's metadata, hooks, history, ignored
// outputs or dependency folders.
type Materialized struct {
	Dir      string
	Paths    []string          // every entry of the tree, in tree order
	Inputs   map[string]Input  // the state of each path when written
	Gitlinks map[string]string // gitlink path -> commit id
	repo     *Repo
}

// Materialize writes tree into dir (created if needed) with modes, symlinks and gitlink
// placeholder directories, then makes dir a repository whose index and HEAD hold exactly
// that tree, populated from the exact blob identities without checkout or attribute
// filters. Entry paths that are absolute, climb out, name .git, or pass through a symlink are refused.
func (r *Repo) Materialize(tree, dir string) (*Materialized, error) {
	if err := checkRev(tree); err != nil {
		return nil, err
	}
	dir, err := filepath.Abs(dir)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	format, err := r.okTrim(nil, "rev-parse", "--show-object-format")
	if err != nil {
		return nil, err
	}
	scratch := &Repo{Dir: dir, Env: r.Env}
	if _, err := scratch.ok(nil, "init", "-q", "--template=", "--object-format="+format); err != nil {
		return nil, err
	}
	entries, err := r.TreeEntries(tree)
	if err != nil {
		return nil, err
	}
	blobs, err := r.openBlobs()
	if err != nil {
		return nil, err
	}
	defer blobs.close()

	var hashed, hashedWant []string // paths for one batched hash-object, their object ids
	for _, e := range entries {
		target, err := safeTarget(dir, e.Path)
		if err != nil {
			return nil, err
		}
		switch {
		case e.Mode == "120000" && e.Type == "blob":
			var link bytes.Buffer
			if err := blobs.copy(e.Object, &link); err != nil {
				return nil, err
			}
			if err := os.Symlink(link.String(), target); err != nil {
				return nil, err
			}
			if err := scratch.hashStdin(link.Bytes(), e.Object); err != nil {
				return nil, err
			}
		case e.Type == "blob":
			if err := writeBlob(blobs, e, target); err != nil {
				return nil, err
			}
			if strings.ContainsAny(target, "\n") {
				if err := scratch.hashFile(target, e.Object); err != nil {
					return nil, err
				}
			} else {
				hashed, hashedWant = append(hashed, target), append(hashedWant, e.Object)
			}
		case e.Type == "commit":
			if err := os.Mkdir(target, 0o755); err != nil {
				return nil, err
			}
		default:
			return nil, fmt.Errorf("git ls-tree: unsupported entry %s %s %q", e.Mode, e.Type, e.Path)
		}
	}
	if err := scratch.hashFiles(hashed, hashedWant); err != nil {
		return nil, err
	}

	// A new local index and HEAD make declared Git commands usable.
	for batch := range slices.Chunk(entries, 100) {
		args := []string{"update-index", "--add"}
		for _, e := range batch {
			args = append(args, "--cacheinfo", e.Mode, e.Object, e.Path)
		}
		if _, err := scratch.ok(nil, args...); err != nil {
			return nil, err
		}
	}
	got, err := scratch.okTrim(nil, "write-tree")
	if err != nil {
		return nil, err
	}
	if got != tree {
		return nil, fmt.Errorf("materialized tree %s differs from %s", got, tree)
	}
	// The disposable verification repository is not the user's: it reads no global or
	// system Git configuration, so the user's signing and hooks never apply to it and
	// nothing has to be switched off on the command line (GIT-2).
	identity := []string{
		"GIT_AUTHOR_NAME=Kogen Verification", "GIT_AUTHOR_EMAIL=verification@kogen.invalid",
		"GIT_COMMITTER_NAME=Kogen Verification", "GIT_COMMITTER_EMAIL=verification@kogen.invalid",
		"GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1",
	}
	commit, err := scratch.okTrim(identity, "commit-tree", tree, "-m", "Clean candidate verification")
	if err != nil {
		return nil, err
	}
	if _, err := scratch.ok(nil, "update-ref", "HEAD", commit); err != nil {
		return nil, err
	}

	m := &Materialized{Dir: dir, Gitlinks: map[string]string{}, repo: scratch}
	for _, e := range entries {
		m.Paths = append(m.Paths, e.Path)
		if e.Mode == "160000" {
			m.Gitlinks[e.Path] = e.Object
		}
	}
	if m.Inputs, err = inputs(dir, m.Paths); err != nil {
		return nil, err
	}
	return m, nil
}

func writeBlob(blobs *blobStream, e TreeEntry, target string) error {
	f, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return err
	}
	if err := blobs.copy(e.Object, f); err != nil {
		f.Close()
		return err
	}
	mode := fs.FileMode(0o644)
	if e.Mode == "100755" {
		mode = 0o755
	}
	if err := f.Chmod(mode); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

// safeTarget is the place for a tree path inside dir, creating the folders above it.
// Folders are made one at a time and none may be a symlink or a file, so an entry can
// never be written outside dir.
func safeTarget(dir, path string) (string, error) {
	parts := strings.Split(path, "/")
	for _, p := range parts {
		if p == "" || p == "." || p == ".." || strings.EqualFold(p, ".git") || strings.ContainsRune(p, 0) {
			return "", fmt.Errorf("unsafe path in tree: %q", path)
		}
	}
	cur := dir
	for _, p := range parts[:len(parts)-1] {
		cur = filepath.Join(cur, p)
		st, err := os.Lstat(cur)
		switch {
		case errors.Is(err, fs.ErrNotExist):
			if err := os.Mkdir(cur, 0o755); err != nil {
				return "", err
			}
		case err != nil:
			return "", err
		case !st.IsDir():
			return "", fmt.Errorf("unsafe path in tree: %q passes through %q, which is not a folder", path, p)
		}
	}
	return filepath.Join(cur, parts[len(parts)-1]), nil
}

func (r *Repo) hashStdin(data []byte, want string) error {
	res, err := r.exec(r.Dir, nil, bytes.NewReader(data), nil, "hash-object", "-w", "--no-filters", "--stdin")
	return hashed(res, err, []string{want})
}

func (r *Repo) hashFile(path, want string) error {
	res, err := r.exec(r.Dir, nil, nil, nil, "hash-object", "-w", "--no-filters", "--", path)
	return hashed(res, err, []string{want})
}

func (r *Repo) hashFiles(paths, want []string) error {
	if len(paths) == 0 {
		return nil
	}
	in := strings.NewReader(strings.Join(paths, "\n") + "\n")
	res, err := r.exec(r.Dir, nil, in, nil, "hash-object", "-w", "--no-filters", "--stdin-paths")
	return hashed(res, err, want)
}

func hashed(res Result, err error, want []string) error {
	if _, err := okResult(res, err, []string{"hash-object"}); err != nil {
		return err
	}
	got := strings.Fields(res.Stdout)
	if !slices.Equal(got, want) {
		return fmt.Errorf("git hash-object wrote %v, want %v", got, want)
	}
	return nil
}

// blobStream reads blobs from one `git cat-file --batch` process.
type blobStream struct {
	cmd  *exec.Cmd
	in   io.WriteCloser
	out  *bufio.Reader
	errb *bytes.Buffer
}

func (r *Repo) openBlobs() (*blobStream, error) {
	cmd := exec.Command(r.gitBinary(), "cat-file", "--batch")
	cmd.Dir = r.Dir
	cmd.Env = r.environ(nil)
	in, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	b := &blobStream{cmd: cmd, in: in, out: bufio.NewReader(out), errb: &bytes.Buffer{}}
	cmd.Stderr = b.errb
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("git: %w", err)
	}
	return b, nil
}

// copy writes the content of blob oid to w.
func (b *blobStream) copy(oid string, w io.Writer) error {
	if _, err := io.WriteString(b.in, oid+"\n"); err != nil {
		return b.fail(oid, err)
	}
	line, err := b.out.ReadString('\n')
	if err != nil {
		return b.fail(oid, err)
	}
	f := strings.Fields(line)
	if len(f) != 3 || f[0] != oid || f[1] != "blob" {
		return fmt.Errorf("git cat-file: %s: %s", oid, strings.TrimSpace(line))
	}
	size, err := strconv.ParseInt(f[2], 10, 64)
	if err != nil {
		return fmt.Errorf("git cat-file: %s: %w", oid, err)
	}
	if _, err := io.CopyN(w, b.out, size); err != nil {
		return b.fail(oid, err)
	}
	if _, err := b.out.ReadByte(); err != nil { // the newline after the content
		return b.fail(oid, err)
	}
	return nil
}

func (b *blobStream) fail(oid string, err error) error {
	return fmt.Errorf("git cat-file %s: %w: %s", oid, err, strings.TrimSpace(b.errb.String()))
}

func (b *blobStream) close() {
	b.in.Close()
	b.cmd.Wait()
}

func inputs(dir string, paths []string) (map[string]Input, error) {
	m := make(map[string]Input, len(paths))
	for _, p := range paths {
		in, err := inputAt(filepath.Join(dir, p))
		if err != nil {
			return nil, err
		}
		m[p] = in
	}
	return m, nil
}

func inputAt(full string) (Input, error) {
	st, err := os.Lstat(full)
	switch {
	case errors.Is(err, fs.ErrNotExist) || errors.Is(err, syscall.ENOTDIR):
		return Input{Kind: "missing"}, nil
	case err != nil:
		return Input{}, err
	}
	switch {
	case st.Mode()&fs.ModeSymlink != 0:
		target, err := os.Readlink(full)
		return Input{Kind: "symlink", Target: target}, err
	case st.Mode().IsRegular():
		data, err := os.ReadFile(full)
		if err != nil {
			return Input{}, err
		}
		return Input{Kind: "file", Exec: uint32(st.Mode().Perm()) & 0o111, Digest: sha256.Sum256(data)}, nil
	case st.IsDir():
		return Input{Kind: "directory"}, nil
	}
	return Input{Kind: "other"}, nil
}

// Mutations lists the candidate inputs that changed in the verification directory since
// Materialize, and the non-ignored files added there. Commands may stage generated files,
// so the additions come from the filesystem and an empty private index, never from the
// directory's own index. Changed gitlink checkouts are listed too. Ignored generated
// outputs do not count (VER-9).
func (m *Materialized) Mutations() ([]string, error) {
	index := sys.TmpPath("kogen-verify-index")
	defer os.Remove(index)
	env := []string{"GIT_INDEX_FILE=" + index}
	if _, err := m.repo.ok(env, "read-tree", "--empty"); err != nil {
		return nil, err
	}
	out, err := m.repo.ok(env, "ls-files", "--others", "--exclude-standard", "-z")
	if err != nil {
		return nil, err
	}
	others := splitNUL(out)

	after, err := inputs(m.Dir, m.Paths)
	if err != nil {
		return nil, err
	}
	var changed []string
	for _, p := range m.Paths {
		if m.Inputs[p] != after[p] {
			changed = append(changed, p)
		}
	}
	known := make(map[string]bool, len(m.Paths))
	for _, p := range m.Paths {
		known[p] = true
	}
	for _, p := range others {
		if _, link := m.Gitlinks[strings.TrimRight(p, "/")]; !known[p] && !link {
			changed = append(changed, p)
		}
	}
	links := make([]string, 0, len(m.Gitlinks))
	for p := range m.Gitlinks {
		links = append(links, p)
	}
	slices.Sort(links)
	for _, p := range links {
		if m.gitlinkChanged(p, m.Gitlinks[p]) {
			changed = append(changed, p)
		}
	}
	return unique(changed), nil
}

// unique removes later duplicates, keeping the first occurrence's order.
func unique(paths []string) []string {
	seen := make(map[string]bool, len(paths))
	out := paths[:0:0]
	for _, p := range paths {
		if !seen[p] {
			seen[p] = true
			out = append(out, p)
		}
	}
	return out
}

// gitlinkChanged reports a gitlink path that holds its own repository whose HEAD is not
// the pinned commit or whose work tree differs from that commit.
func (m *Materialized) gitlinkChanged(path, commit string) bool {
	full := filepath.Join(m.Dir, path)
	if st, err := os.Stat(full); err != nil || !st.IsDir() {
		return false
	}
	if top, ok := Root(full, m.repo.Env); !ok || top != full {
		return false
	}
	nested := m.repo.At(full)
	if nested.Head() != commit {
		return true
	}
	have, err := nested.Tree(commit, nil)
	if err != nil {
		return true
	}
	want, err := nested.Resolve(commit + "^{tree}")
	return err != nil || have != want
}
