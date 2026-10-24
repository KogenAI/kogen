package build

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"

	"kogen/git"
	"kogen/project"
	"kogen/sys"
)

// Recover is `kogen intent recover <build-id> --output <new-external-directory>`: the
// explicit preservation and implementation-only cleanup of a completed, builder-reported
// protected blocker. The stopped Build's before and candidate bytes of every implementation
// path, its checkpoint, index backup, approval, result and blocker are first preserved
// durably in a NEW directory outside the checkout, with a manifest and a diagnostic
// handoff; only then is exactly the recorded implementation delta cleared from the
// checkout (never protected files, the index, other paths or other contents). Nothing is
// refined, approved, resumed or imported, and the old green evidence stays unusable.
type RecoverInput struct {
	Project string
	ID      string
	// Output is the new directory, absolute.
	Output string
}

const recoveryHandoffLimit = 262_144

// RawMeta is the identity of one side of a path: its Git mode and the SHA-256 of its bytes
// (a symbolic link's target for 120000).
type RawMeta struct {
	Mode   string `json:"mode"`
	SHA256 string `json:"sha256"`
}

// rawSide is a path as the checkout holds it, or as a tree holds it: mode and bytes.
type rawSide struct {
	mode  string
	bytes []byte
}

func (r *rawSide) meta() *RawMeta {
	if r == nil {
		return nil
	}
	sum := sha256.Sum256(r.bytes)
	return &RawMeta{Mode: r.mode, SHA256: hex.EncodeToString(sum[:])}
}

func sameSide(a, b *rawSide) bool {
	if a == nil || b == nil {
		return a == b
	}
	return a.mode == b.mode && bytes.Equal(a.bytes, b.bytes)
}

func recoveryRefused(why, kind string) *sys.Error {
	if kind == "" {
		kind = "recovery_refused"
	}
	return sys.Fail("candidate", kind, why+
		"; inspect the run/receipt and checkout; correct the named fact or use ordinary Refine and fresh exact approval", 1)
}

// Recover runs the recovery and returns the command's exit code.
func Recover(_ context.Context, s *sys.Session, in RecoverInput) (int, error) {
	repo, err := git.Open(in.Project, s.Env)
	if err != nil {
		return 0, err
	}
	lock, err := git.AcquireBuild(repo.Dir, s)
	if err != nil {
		return 0, err
	}
	defer lock.Release()
	rc := &recovery{s: s, repo: repo, root: repo.Dir, id: in.ID, output: filepath.Clean(in.Output)}
	if err := rc.run(); err != nil {
		var e *sys.Error
		switch {
		case errors.As(err, &e) && (e.Reason == "recovery_refused" || e.Reason == "recovery_unsupported"):
			return 0, err
		case errors.As(err, &e):
			return 0, recoveryRefused(e.Class+"/"+e.Reason+": "+e.Detail, "")
		}
		var interrupted *sys.Interrupted
		if errors.As(err, &interrupted) {
			return 0, err
		}
		return 0, recoveryRefused(err.Error(), "")
	}
	return 0, nil
}

type recovery struct {
	s      *sys.Session
	repo   *git.Repo
	root   string
	id     string
	output string

	b      *State
	doc    Checkpoint
	dir    string
	approv []byte
	index  []byte
}

func require(ok bool, why string) error {
	if ok {
		return nil
	}
	return recoveryRefused(why, "")
}

// safePath refuses a path any component of which is missing or neither a regular file nor a
// directory (a symbolic link, anywhere along it).
func safePath(path string) error {
	path = filepath.Clean(path)
	parts := strings.Split(strings.TrimPrefix(path, "/"), "/")
	full := "/"
	for _, part := range parts {
		if part == "" {
			continue
		}
		full = filepath.Join(full, part)
		st, err := os.Lstat(full)
		if err != nil || !(st.Mode().IsRegular() || st.IsDir()) {
			return recoveryRefused("unsafe/symlinked or missing custody: "+full, "")
		}
	}
	return nil
}

func readSafe(path string) ([]byte, error) {
	if err := safePath(path); err != nil {
		return nil, err
	}
	st, err := os.Stat(path)
	if err != nil || !st.Mode().IsRegular() {
		return nil, recoveryRefused("not regular custody: "+path, "")
	}
	return os.ReadFile(path)
}

func sha(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

func (r *recovery) run() error {
	root, id := r.root, r.id
	if !buildID.MatchString(id) {
		return recoveryRefused("unknown checkpoint", "recovery_unsupported")
	}
	r.dir = filepath.Join(root, ".kogen/local/runs", id)
	cp := filepath.Join(r.dir, "checkpoint.json")
	if _, err := os.Stat(cp); err != nil {
		return recoveryRefused("absent checkpoint", "recovery_unsupported")
	}
	raw, err := readSafe(cp)
	if err != nil {
		return err
	}
	if v, err := decodeJSONNumbers(raw); err == nil {
		if m, ok := v.(map[string]any); ok {
			if version, ok := m["version"]; ok {
				if n, _ := version.(json.Number); n != "3" && n != "4" {
					return recoveryRefused("legacy checkpoint version "+inspectScalar(version), "recovery_unsupported")
				}
			}
		}
	}
	loaded, why := decodeCheckpoint(raw, newLegacy(Deps{}))
	if why != "" {
		return recoveryRefused(why, "")
	}
	b, doc := loaded.State, loaded.Doc
	r.b, r.doc = b, doc

	identity, err := fileIdentity(root)
	if err != nil {
		return err
	}
	if err := require(b.Root == root && doc.Identity == identity, "checkout identity changed"); err != nil {
		return err
	}
	gitIndex, err := r.repo.IndexPath()
	if err != nil {
		return err
	}
	if err := require(b.Run.ID == id && b.Run.Dir == r.dir && b.Run.LogPath == filepath.Join(r.dir, "log.jsonl") && b.GitIndex == gitIndex,
		"checkpoint run/index paths changed"); err != nil {
		return err
	}
	if err := require(validBuilderBlocker(b), "not a BUILDER-REPORTED protected blocker"); err != nil {
		return err
	}
	if err := require(!slices.Contains([]string{StageCommit, StageStartup, StageLanded}, b.Continuation.Stage), "uncertain executed boundary"); err != nil {
		return err
	}
	resultBytes, err := readSafe(filepath.Join(r.dir, "result.json"))
	if err != nil {
		return err
	}
	var result map[string]any
	if v, err := decodeJSONNumbers(resultBytes); err != nil {
		return err
	} else if result, _ = v.(map[string]any); result == nil {
		return recoveryRefused("result does not match completed build_blocked report", "")
	}
	if err := require(result["outcome"] == "build_blocked" && canonical(result["blocker"]) == canonical(b.Blocker) &&
		result["build"] == id && result["slug"] == b.Slug && result["start_head"] == b.Start,
		"result does not match completed build_blocked report"); err != nil {
		return err
	}
	if err := (&Attempt{State: *b}).validateWorkingContext(); err != nil {
		return err
	}
	if err := project.ValidateSource(b.SourceProvenance); err != nil {
		return err
	}
	if r.approv, err = decodeBase64(doc.Approval); err != nil {
		return err
	}
	if r.index, err = decodeBase64(doc.Index); err != nil {
		return err
	}
	backup, err := readSafe(filepath.Join(r.dir, "index-at-start"))
	if err != nil {
		return err
	}
	if err := require(bytes.Equal(backup, r.index), "original index backup changed"); err != nil {
		return err
	}
	output := r.output
	if _, err := os.Lstat(output); !errors.Is(err, fs.ErrNotExist) {
		return recoveryRefused("output destination already exists or is unsafe: "+output, "")
	}
	if err := safePath(filepath.Dir(output)); err != nil {
		return err
	}
	if err := require(output != root && !strings.HasPrefix(output, root+"/"), "output destination is inside checkout"); err != nil {
		return err
	}
	recoveries := filepath.Join(root, ".kogen/local/recoveries")
	if _, err := os.Lstat(recoveries); !errors.Is(err, fs.ErrNotExist) {
		if err := safePath(recoveries); err != nil {
			return err
		}
	}
	for _, p := range []string{id + ".json", "checkpoint.json", "checkpoint.json.tmp"} {
		if _, err := os.Lstat(filepath.Join(recoveries, p)); !errors.Is(err, fs.ErrNotExist) {
			return recoveryRefused("existing recovery receipt or unsafe custody: "+p+"; inspect receipt instead", "")
		}
	}
	if err := r.validate(); err != nil {
		return err
	}

	changed, err := r.repo.Changed(b.StartTree, doc.Candidate)
	if err != nil {
		return err
	}
	var paths []string
	for _, p := range changed {
		if slices.Contains(b.Baseline, p) {
			continue
		}
		skip := false
		for _, e := range b.Excluded {
			if p == e || strings.HasPrefix(p, e+"/") {
				skip = true
			}
		}
		if !skip {
			paths = append(paths, p)
		}
	}
	slices.Sort(paths)

	type change struct {
		path          string
		before, after *rawSide
	}
	changes := make([]change, 0, len(paths))
	for _, p := range paths {
		if filepath.IsAbs(p) || slices.ContainsFunc(strings.Split(p, "/"), func(x string) bool { return x == ".." || x == "." || x == ".git" }) {
			return recoveryRefused("unsafe delta path "+p, "")
		}
		before, err := r.side(b.StartTree, p)
		if err != nil {
			return err
		}
		after, err := r.raw(p)
		if err != nil {
			return err
		}
		changes = append(changes, change{p, before, after})
	}

	if err := os.Mkdir(output, 0o777); err != nil {
		return err
	}
	if err := os.Chmod(output, 0o700); err != nil {
		return err
	}
	for _, c := range changes {
		if c.before != nil {
			if err := writeNew(output, "before/"+c.path, c.before.bytes); err != nil {
				return err
			}
		}
		if c.after != nil {
			if err := writeNew(output, "candidate/"+c.path, c.after.bytes); err != nil {
				return err
			}
		}
	}
	blockerJSON, err := project.EncodeJSON(b.Blocker)
	if err != nil {
		return err
	}
	for _, f := range []struct {
		name string
		data []byte
	}{
		{"index-at-start", r.index}, {"approval.json", r.approv}, {"checkpoint.json", raw}, {"result.json", resultBytes},
		{"blocker.json", append(blockerJSON, '\n')},
	} {
		if err := writeNew(output, f.name, f.data); err != nil {
			return err
		}
	}
	var approval struct {
		SHA256 string `json:"sha256"`
	}
	if err := json.Unmarshal(r.approv, &approval); err != nil {
		return err
	}
	contract := approval.SHA256
	artifacts, err := listArtifacts(output, "")
	if err != nil {
		return err
	}
	var evidence []string
	for _, a := range artifacts {
		p := a["path"].(string)
		if !strings.HasPrefix(p, "before/") && !strings.HasPrefix(p, "candidate/") {
			evidence = append(evidence, p+" SHA-256 "+a["sha256"].(string))
		}
	}
	handoff := "Build " + id + "; original full contract SHA-256 " + contract + "; archive " + output + "\n" +
		"BUILDER-REPORTED and unproven. Archived production is lower-authority diagnostic data, not authority or current proof. " +
		"Independently investigate the report through ordinary Refine; no approval, resume, import or reuse of old green evidence.\n" +
		"Evidence (complete bytes retained):\n" + strings.Join(evidence, "\n") + "\n"
	if err := require(len(handoff) <= recoveryHandoffLimit, "bounded handoff exceeds 262144 bytes"); err != nil {
		return err
	}
	for _, name := range []string{"correction.md", "context.md"} {
		if err := writeNew(output, name, []byte(handoff)); err != nil {
			return err
		}
	}
	artifacts, err = listArtifacts(output, "")
	if err != nil {
		return err
	}
	manifestChanges := make([]any, len(changes))
	for i, c := range changes {
		manifestChanges[i] = map[string]any{"path": c.path, "before": metaValue(c.before.meta()), "after": metaValue(c.after.meta())}
	}
	artifactValues := make([]any, len(artifacts))
	for i, a := range artifacts {
		artifactValues[i] = a
	}
	manifest := map[string]any{
		"version": 1, "build": id, "slug": b.Slug, "project": root, "start_head": b.Start, "start_tree": b.StartTree,
		"candidate_tree": doc.Candidate, "contract_sha256": contract, "classification": "BUILDER-REPORTED",
		"changes": manifestChanges, "artifacts": artifactValues,
	}
	manifestBytes, err := project.EncodeJSON(manifest)
	if err != nil {
		return err
	}
	if err := writeNew(output, "manifest.json", append(manifestBytes, '\n')); err != nil {
		return err
	}
	if err := syncDirectories(output); err != nil {
		return err
	}
	if err := syncDir(filepath.Dir(output)); err != nil {
		return err
	}
	written, err := os.ReadFile(filepath.Join(output, "manifest.json"))
	if err != nil {
		return err
	}
	manifestHash := sha(written)
	receipt := map[string]any{"build": id, "archive": output, "manifest_sha256": manifestHash, "state": "preserved"}
	if err := r.receipt(receipt); err != nil {
		return err
	}
	r.s.Puts("Preserved " + output + "/manifest.json SHA-256 " + manifestHash)

	if err := r.validate(); err != nil {
		return err
	}
	again, err1 := readSafe(cp)
	again2, err2 := readSafe(filepath.Join(r.dir, "result.json"))
	again3, err3 := readSafe(filepath.Join(r.dir, "index-at-start"))
	if err := errors.Join(err1, err2, err3); err != nil {
		return err
	}
	if err := require(bytes.Equal(again, raw) && bytes.Equal(again2, resultBytes) && bytes.Equal(again3, r.index),
		"retained run evidence changed after preservation; inspect preserved archive"); err != nil {
		return err
	}
	for _, a := range artifacts {
		data, err := readSafe(filepath.Join(output, a["path"].(string)))
		if err != nil {
			return err
		}
		if err := require(sha(data) == a["sha256"], "published archive changed: "+a["path"].(string)); err != nil {
			return err
		}
	}
	data, err := readSafe(filepath.Join(output, "manifest.json"))
	if err != nil {
		return err
	}
	if err := require(sha(data) == manifestHash, "published manifest changed"); err != nil {
		return err
	}
	for _, c := range changes {
		now, err := r.raw(c.path)
		if err != nil {
			return err
		}
		if err := require(sameSide(now, c.after), "candidate drift before cleanup: "+c.path); err != nil {
			return err
		}
	}

	cleaned := func() error {
		sides := make([]pathSide, len(changes))
		for i, c := range changes {
			sides[i] = pathSide{c.path, c.before}
		}
		if err := r.restoreDelta(sides); err != nil {
			return err
		}
		current, err := os.ReadFile(r.b.GitIndex)
		if err != nil || !bytes.Equal(current, r.index) {
			return errors.New("index changed during cleanup")
		}
		cleanedReceipt := map[string]any{}
		for k, v := range receipt {
			cleanedReceipt[k] = v
		}
		cleanedReceipt["state"] = "cleaned"
		return r.receipt(cleanedReceipt)
	}()
	if cleaned != nil {
		// Only roll back our recorded delta, never protected files or the index.
		sides := make([]pathSide, len(changes))
		for i, c := range changes {
			sides[i] = pathSide{c.path, c.after}
		}
		rollback := "candidate bytes restored"
		if err := r.restoreDelta(sides); err != nil {
			rollback = "candidate restoration incomplete: " + err.Error()
		}
		return recoveryRefused("archive durably preserved at "+output+"; cleanup incomplete: "+cleaned.Error()+"; "+rollback+
			"; inspect preserved receipt, do not retry/guess reconciliation", "")
	}

	q := shellQuote(root)
	r.s.Puts("kogen intent refine " + b.Slug + " " + contract + " " + shellQuote(filepath.Join(output, "correction.md")) + " --project " + q)
	r.s.Puts("Review the corrected package and freshly approve its new exact hash:")
	r.s.Puts("kogen intent approve " + b.Slug + " --project " + q)
	r.s.Puts("kogen intent approve " + b.Slug + " <new-full-sha256> --project " + q)
	r.s.Puts("Then start a FRESH Build:")
	r.s.Puts("kogen intent build " + b.Slug + " --context " + shellQuote(filepath.Join(output, "context.md")) + " --project " + q)
	return nil
}

func metaValue(m *RawMeta) any {
	if m == nil {
		return nil
	}
	return map[string]any{"mode": m.Mode, "sha256": m.SHA256}
}

// validBuilderBlocker is whether the saved blocker is exactly a builder-reported protected
// contradiction: nonempty unique protected paths, a reason and evidence.
func validBuilderBlocker(b *State) bool {
	bl := b.Blocker
	if bl == nil || len(bl) != 4 || bl["classification"] != "BUILDER-REPORTED" {
		return false
	}
	for _, k := range []string{"evidence", "paths", "reason", "classification"} {
		if _, ok := bl[k]; !ok {
			return false
		}
	}
	paths, ok := bl["paths"].([]any)
	if !ok || len(paths) == 0 {
		return false
	}
	seen := map[string]bool{}
	for _, p := range paths {
		s, ok := p.(string)
		if !ok || seen[s] || !slices.Contains(b.Baseline, s) {
			return false
		}
		seen[s] = true
	}
	for _, k := range []string{"reason", "evidence"} {
		if s, ok := bl[k].(string); !ok || strings.TrimSpace(s) == "" {
			return false
		}
	}
	return true
}

// validate is the state of the checkout a recovery needs, before preserving and again before
// cleaning.
func (r *recovery) validate() error {
	b, doc := r.b, r.doc
	op, err := r.repo.OperationInProgress()
	if err != nil {
		return err
	}
	if err := require(op == "", "active Git operation"); err != nil {
		return err
	}
	locked := false
	filepath.WalkDir(filepath.Dir(b.GitIndex), func(path string, d fs.DirEntry, err error) error {
		if err == nil && path != filepath.Dir(b.GitIndex) && strings.HasSuffix(d.Name(), ".lock") {
			locked = true
		}
		return nil
	})
	if err := require(!locked, "active Git lock"); err != nil {
		return err
	}
	if err := require(r.repo.Head() == b.Start, "HEAD changed"); err != nil {
		return err
	}
	startChanges, err := r.repo.Changed(b.Start, b.StartTree)
	if err != nil {
		return err
	}
	if err := require(!slices.ContainsFunc(startChanges, func(p string) bool { return !slices.Contains(b.Baseline, p) }),
		"start tree contains unapproved production changes"); err != nil {
		return err
	}
	current, err := readSafe(b.GitIndex)
	if err != nil {
		return err
	}
	if err := require(bytes.Equal(current, r.index), "index changed"); err != nil {
		return err
	}
	approval, err := readSafe(project.ApprovalPath(r.root, b.Slug))
	if err != nil {
		return err
	}
	if err := require(bytes.Equal(approval, r.approv), "approval changed"); err != nil {
		return err
	}
	for _, p := range b.Baseline {
		if err := require(fileDigest(r.root, p) == b.BaselineDigests[p], "protected baseline changed: "+p); err != nil {
			return err
		}
	}
	cfg, err := project.LoadConfig(r.root)
	if err != nil {
		return err
	}
	baseline, err := project.Baseline(r.root, b.Slug, b.Config)
	if err != nil {
		return err
	}
	if err := require(sameConfig(cfg, b.Config) && slices.Equal(baseline, b.Baseline), "protected baseline/configuration changed"); err != nil {
		return err
	}
	tree, err := r.repo.Tree(b.Start, nil)
	if err != nil {
		return err
	}
	if err := require(tree == doc.Candidate, "complete stopped candidate changed"); err != nil {
		return err
	}
	identity, err := rawIdentity(r.repo, r.root, b.StartTree)
	if err != nil {
		return err
	}
	return require(doc.RecoveryRaw != nil && canonical(doc.RecoveryRaw) == canonical(identity), "raw candidate identity changed or missing")
}

// side is path as the tree holds it: nil for a path the tree lacks (or a directory).
func (r *recovery) side(tree, path string) (*rawSide, error) {
	out, err := r.repo.OK("ls-tree", "-z", tree, "--", ":(literal)"+path)
	if err != nil {
		return nil, err
	}
	meta, _, ok := strings.Cut(out, "\t")
	if !ok {
		return nil, nil
	}
	f := strings.Split(meta, " ")
	if len(f) != 3 {
		return nil, fmt.Errorf("git ls-tree: unexpected entry %q", out)
	}
	mode, typ, object := f[0], f[1], f[2]
	if typ == "tree" {
		return nil, nil
	}
	if !(typ == "blob" && slices.Contains([]string{"100644", "100755", "120000"}, mode)) {
		return nil, recoveryRefused("unsupported delta mode "+mode+": "+path, "")
	}
	blob, err := r.repo.OK("cat-file", "blob", object)
	if err != nil {
		return nil, err
	}
	return &rawSide{mode, []byte(blob)}, nil
}

// raw is path as the checkout holds it: a regular file or symbolic link, nil for anything
// absent or a directory. A leaf whose parent is no longer a real directory is absent: a
// replacement symbolic link is never followed.
func (r *recovery) raw(p string) (*rawSide, error) { return rawOf(r.root, p) }

func rawOf(root, p string) (*rawSide, error) {
	parts := strings.Split(p, "/")
	dir := root
	for _, part := range parts[:len(parts)-1] {
		dir = filepath.Join(dir, part)
		if st, err := os.Lstat(dir); err != nil || !st.IsDir() {
			return nil, nil
		}
	}
	path := filepath.Join(root, p)
	st, err := os.Lstat(path)
	switch {
	case err != nil:
		if errors.Is(err, fs.ErrNotExist) || errors.Is(err, syscall.ENOTDIR) {
			return nil, nil
		}
		return nil, recoveryRefused("unsafe candidate path "+p, "")
	case st.IsDir():
		return nil, nil
	case st.Mode()&fs.ModeSymlink != 0:
		if err := safePath(filepath.Dir(path)); err != nil {
			return nil, err
		}
		target, err := os.Readlink(path)
		if err != nil {
			return nil, err
		}
		return &rawSide{"120000", []byte(target)}, nil
	case st.Mode().IsRegular():
		if err := safePath(filepath.Dir(path)); err != nil {
			return nil, err
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		mode := "100644"
		if st.Mode().Perm()&0o111 != 0 {
			mode = "100755"
		}
		return &rawSide{mode, data}, nil
	}
	return nil, recoveryRefused("unsafe candidate path "+p, "")
}

// rawIdentity is the identity of every implementation path of the candidate that differs
// from the Build's start tree, as the checkout holds it: recorded in each checkpoint of a
// Build that reported a blocker, so a recovery can prove nothing changed since.
func rawIdentity(repo *git.Repo, root, startTree string) (map[string]*RawMeta, error) {
	candidate, err := repo.Tree(startTree, nil)
	if err != nil {
		return nil, err
	}
	changed, err := repo.Changed(startTree, candidate)
	if err != nil {
		return nil, err
	}
	out := make(map[string]*RawMeta, len(changed))
	for _, p := range changed {
		side, err := rawOf(root, p)
		if err != nil {
			return nil, err
		}
		out[p] = side.meta()
	}
	return out, nil
}

// writeNew creates dir/p privately (0700 folders, 0600 file, exclusive, synced).
func writeNew(dir, p string, data []byte) error {
	path := filepath.Join(dir, p)
	if err := mkdirPrivate(filepath.Dir(path)); err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	err = f.Chmod(0o600)
	if err == nil {
		_, err = f.Write(data)
	}
	if err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return err
}

func mkdirPrivate(path string) error {
	if st, err := os.Stat(path); err == nil && st.IsDir() {
		return nil
	}
	if err := mkdirPrivate(filepath.Dir(path)); err != nil {
		return err
	}
	if err := os.Mkdir(path, 0o777); err != nil {
		return err
	}
	return os.Chmod(path, 0o700)
}

// listArtifacts lists every file under dir/prefix with its SHA-256, sorted by path.
func listArtifacts(dir, prefix string) ([]map[string]any, error) {
	entries, err := os.ReadDir(filepath.Join(dir, prefix))
	if err != nil {
		return nil, err
	}
	var out []map[string]any
	for _, e := range entries {
		p := filepath.Join(prefix, e.Name())
		full := filepath.Join(dir, p)
		if st, err := os.Stat(full); err == nil && st.IsDir() {
			sub, err := listArtifacts(dir, p)
			if err != nil {
				return nil, err
			}
			out = append(out, sub...)
			continue
		}
		data, err := os.ReadFile(full)
		if err != nil {
			return nil, err
		}
		out = append(out, map[string]any{"path": p, "sha256": sha(data)})
	}
	slices.SortFunc(out, func(a, b map[string]any) int { return strings.Compare(a["path"].(string), b["path"].(string)) })
	return out, nil
}

// receipt publishes the recovery receipt `.kogen/local/recoveries/<id>.json` atomically.
func (r *recovery) receipt(data map[string]any) error {
	dir := filepath.Join(r.root, ".kogen/local/recoveries")
	if err := mkdirPrivate(dir); err != nil {
		return err
	}
	run := &Run{Dir: dir}
	if err := run.PublishCheckpoint(data); err != nil {
		return err
	}
	if err := os.Rename(filepath.Join(dir, "checkpoint.json"), filepath.Join(dir, r.id+".json")); err != nil {
		return err
	}
	if err := syncDir(dir); err != nil {
		return err
	}
	return syncDir(filepath.Dir(dir))
}

func syncDirectories(dir string) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	for _, e := range entries {
		if st, err := os.Stat(filepath.Join(dir, e.Name())); err == nil && st.IsDir() {
			if err := syncDirectories(filepath.Join(dir, e.Name())); err != nil {
				return err
			}
		}
	}
	return syncDir(dir)
}

func syncDir(dir string) error {
	f, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer f.Close()
	return f.Sync()
}

// pathSide is a path and the side it should be restored to (nil: absent).
type pathSide struct {
	path string
	side *rawSide
}

// restoreDelta puts the recorded paths back to the given sides: first only recorded leaves
// that differ are removed, deepest first, then every target is created shallowest first, and
// empty directories left over are removed with rmdir, never recursively.
func (r *recovery) restoreDelta(sides []pathSide) error {
	depth := func(p string) int { return len(strings.Split(p, "/")) }
	byDepth := slices.Clone(sides)
	slices.SortStableFunc(byDepth, func(a, b pathSide) int { return depth(b.path) - depth(a.path) })
	for _, s := range byDepth {
		current, err := r.raw(s.path)
		if err != nil {
			return err
		}
		if current != nil && !sameSide(current, s.side) {
			if err := os.Remove(filepath.Join(r.root, s.path)); err != nil {
				return err
			}
		}
	}
	slices.SortStableFunc(byDepth, func(a, b pathSide) int { return depth(a.path) - depth(b.path) })
	for _, s := range byDepth {
		current, err := r.raw(s.path)
		if err != nil {
			return err
		}
		if !sameSide(current, s.side) {
			if err := r.replace(s.path, s.side); err != nil {
				return err
			}
		}
	}
	for _, s := range sides {
		now, err := r.raw(s.path)
		if err != nil {
			return err
		}
		if err := require(sameSide(now, s.side), "restored bytes/mode mismatch: "+s.path); err != nil {
			return err
		}
	}
	return nil
}

func (r *recovery) ensureParent(path string) error {
	st, err := os.Lstat(path)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		if err := r.ensureParent(filepath.Dir(path)); err != nil {
			return err
		}
		return os.Mkdir(path, 0o777)
	case err == nil && st.IsDir():
		return safePath(path)
	}
	return recoveryRefused("unsafe cleanup parent "+path, "")
}

func (r *recovery) removeEmptyDirectory(path string) error {
	entries, err := os.ReadDir(path)
	if err != nil {
		return err
	}
	for _, e := range entries {
		full := filepath.Join(path, e.Name())
		if st, err := os.Lstat(full); err != nil || !st.IsDir() {
			return recoveryRefused("unrecorded cleanup content: "+full, "")
		}
		if err := r.removeEmptyDirectory(full); err != nil {
			return err
		}
	}
	return os.Remove(path)
}

func (r *recovery) replace(p string, side *rawSide) error {
	path := filepath.Join(r.root, p)
	if err := r.ensureParent(filepath.Dir(path)); err != nil {
		return err
	}
	st, err := os.Lstat(path)
	switch {
	case err == nil && st.IsDir():
		if err := r.removeEmptyDirectory(path); err != nil {
			return err
		}
	case err == nil && (st.Mode().IsRegular() || st.Mode()&fs.ModeSymlink != 0):
		if err := os.Remove(path); err != nil {
			return err
		}
	case errors.Is(err, fs.ErrNotExist):
	default:
		return recoveryRefused("unsafe cleanup target "+p, "")
	}
	switch {
	case side == nil:
		return nil
	case side.mode == "120000":
		return os.Symlink(string(side.bytes), path)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o777); err != nil {
		return err
	}
	if err := os.WriteFile(path, side.bytes, 0o666); err != nil {
		return err
	}
	perm := os.FileMode(0o644)
	if side.mode == "100755" {
		perm = 0o755
	}
	return os.Chmod(path, perm)
}
