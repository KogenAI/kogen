package build

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"syscall"

	"kogen/project"
)

// baselineIdentity is deliberately independent of shell dependency fingerprinting: only the
// internal colon evaluator may use it. Two complete scans guard against unstable trees.
func baselineIdentity(root string, checks []project.Check) (string, string, error) {
	cmd := exec.Command("git", "rev-parse", "--git-common-dir")
	cmd.Dir = root
	out, err := cmd.Output()
	if err != nil {
		return "", "", err
	}
	common := strings.TrimSpace(string(out))
	if !filepath.IsAbs(common) {
		common = filepath.Join(root, common)
	}
	common, err = filepath.EvalSymlinks(common)
	if err != nil {
		return "", "", err
	}
	common, err = filepath.Abs(common)
	if err != nil {
		return "", "", err
	}
	exe, err := os.Executable()
	if err != nil {
		return "", "", err
	}
	executable, err := os.ReadFile(exe)
	if err != nil {
		return "", "", err
	}
	env := os.Environ()
	sort.Strings(env)
	scan := func() (string, error) {
		h := sha256.New()
		put := func(v any) { b, _ := json.Marshal(v); fmt.Fprintf(h, "%d:", len(b)); h.Write(b) }
		put("kogen-baseline-v1")
		put(common)
		put(checks)
		put(env)
		put(sha256.Sum256(executable))
		err := filepath.WalkDir(root, func(path string, d fs.DirEntry, e error) error {
			if e != nil {
				return e
			}
			rel, e := filepath.Rel(root, path)
			if e != nil {
				return e
			}
			if rel == ".git" || rel == filepath.Join(".kogen", "local") {
				if d.IsDir() {
					return filepath.SkipDir
				}
				return nil
			}
			if rel == "." {
				return nil
			}
			st, e := os.Lstat(path)
			if e != nil {
				return e
			}
			put(rel)
			put(uint32(st.Mode()))
			switch {
			case st.Mode().IsRegular():
				fd, e := syscall.Open(path, syscall.O_RDONLY|syscall.O_NOFOLLOW, 0)
				if e != nil {
					return e
				}
				f := os.NewFile(uintptr(fd), path)
				ch := sha256.New()
				_, e = io.Copy(ch, f)
				after, se := f.Stat()
				pathAfter, pe := os.Lstat(path)
				ce := f.Close()
				if e != nil {
					return e
				}
				if se != nil {
					return se
				}
				if ce != nil {
					return ce
				}
				if pe != nil {
					return pe
				}
				if !pathAfter.Mode().IsRegular() || !os.SameFile(st, pathAfter) {
					return fmt.Errorf("unstable path %s", rel)
				}
				if !os.SameFile(st, after) || st.Size() != after.Size() || !st.ModTime().Equal(after.ModTime()) {
					return fmt.Errorf("unstable file %s", rel)
				}
				put(hex.EncodeToString(ch.Sum(nil)))
			case st.Mode()&os.ModeSymlink != 0:
				target, e := os.Readlink(path)
				if e != nil {
					return e
				}
				put(target)
			case st.IsDir():
			default:
				return fmt.Errorf("unsupported file %s", rel)
			}
			return nil
		})
		if err != nil {
			return "", err
		}
		return hex.EncodeToString(h.Sum(nil)), nil
	}
	a, err := scan()
	if err != nil {
		return "", "", err
	}
	b, err := scan()
	if err != nil {
		return "", "", err
	}
	if a != b {
		return "", "", fmt.Errorf("unstable tree")
	}
	return a, filepath.Join(common, "kogen-baselines"), nil
}

type baselineEvidence struct {
	Version   int     `json:"version"`
	Complete  bool    `json:"complete"`
	Command   string  `json:"command"`
	Status    *int    `json:"status"`
	Output    *string `json:"output"`
	Position  *int    `json:"position"`
	Identity  string  `json:"identity"`
	Index     int     `json:"index"`
	Name      string  `json:"name"`
	Reference string  `json:"reference"`
}

func baselineCachePath(dir, digest string, index int) string {
	return filepath.Join(dir, fmt.Sprintf("%s-%d.json", digest, index))
}
func readBaselineEvidence(dir, digest string, index int, name string) (baselineEvidence, bool) {
	var e baselineEvidence
	raw, err := os.ReadFile(baselineCachePath(dir, digest, index))
	if err != nil || json.Unmarshal(raw, &e) != nil {
		return e, false
	}
	return e, e.Version == 2 && e.Complete && e.Command == ":" && e.Status != nil && *e.Status == 0 && e.Output != nil && *e.Output == "" && e.Position != nil && *e.Position == index && e.Identity == digest && e.Index == index && e.Name == name && e.Reference != ""
}
func publishBaselineEvidence(dir string, e baselineEvidence) {
	if os.MkdirAll(dir, 0700) != nil {
		return
	}
	f, err := os.CreateTemp(dir, ".baseline-")
	if err != nil {
		return
	}
	defer os.Remove(f.Name())
	raw, err := json.Marshal(e)
	if err == nil {
		_, err = f.Write(raw)
	}
	if err == nil {
		err = f.Sync()
	}
	if closeErr := f.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return
	}
	_ = os.Rename(f.Name(), baselineCachePath(dir, e.Identity, e.Index))
}
