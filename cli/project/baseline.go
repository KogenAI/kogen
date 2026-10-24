package project

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
)

// Baseline is the acceptance baseline (VER-1, AUT-2) in card order: the Intent's `intent.md` and
// `acceptance.feature`, its acceptance list, the rest of its files, the project configuration and
// the files `protect` matches, each once.
func Baseline(root, slug string, cfg *Config) ([]string, error) {
	var intentFiles []string
	dir := filepath.Join(root, IntentDir(slug))
	filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() && isRegular(path) {
			if rel, err := filepath.Rel(root, path); err == nil {
				intentFiles = append(intentFiles, filepath.ToSlash(rel))
			}
		}
		return nil
	})
	md, feature := IntentMDPath(slug), FeaturePath(slug)
	slices.SortFunc(intentFiles, func(a, b string) int {
		rank := func(p string) int {
			switch p {
			case md:
				return 0
			case feature:
				return 1
			}
			return 2
		}
		if ra, rb := rank(a), rank(b); ra != rb {
			return ra - rb
		}
		return strings.Compare(a, b)
	})

	var listed []string
	if IntentExists(root, slug) {
		if intent, err := LoadIntent(root, slug); err == nil {
			listed = intent.Acceptance
		}
	}
	var all []string
	for _, p := range []string{md, feature} {
		if slices.Contains(intentFiles, p) {
			all = append(all, p)
		}
	}
	all = append(all, listed...)
	all = append(all, intentFiles...)
	all = append(all, ConfigPath)
	protected, err := Protected(root, cfg)
	if err != nil {
		return nil, err
	}
	return uniqStrings(append(all, protected...)), nil
}

// Protected lists the files matching `protect` (paths, folders or globs) among the tracked and the
// not-ignored untracked files, sorted and without duplicates.
func Protected(root string, cfg *Config) ([]string, error) {
	if len(cfg.Protect) == 0 {
		return nil, nil
	}
	cmd := exec.Command("git", "ls-files", "-z", "--cached", "--others", "--exclude-standard")
	cmd.Dir = root
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("git ls-files failed: %w: %s", err, strings.TrimSpace(stderr.String()))
	}
	var files []string
	for _, f := range strings.Split(string(out), "\x00") {
		if f != "" {
			files = append(files, f)
		}
	}
	var matched []string
	for _, pat := range cfg.Protect {
		pat = strings.TrimRight(pat, "/")
		re := globRegexp(pat)
		for _, f := range files {
			if re.MatchString(f) || strings.HasPrefix(f, pat+"/") {
				matched = append(matched, f)
			}
		}
	}
	matched = uniqStrings(matched)
	slices.Sort(matched)
	return matched, nil
}

// globRegexp turns a protect pattern into an anchored regexp: `**/` any folders, `**` anything,
// `*` anything but a slash, `?` one character but a slash.
func globRegexp(pat string) *regexp.Regexp {
	var b strings.Builder
	b.WriteString("^")
	lit := 0
	flush := func(end int) {
		if end > lit {
			b.WriteString(regexp.QuoteMeta(pat[lit:end]))
		}
	}
	for i := 0; i < len(pat); {
		switch {
		case strings.HasPrefix(pat[i:], "**/"):
			flush(i)
			b.WriteString("(?:.*/)?")
			i += 3
			lit = i
		case strings.HasPrefix(pat[i:], "**"):
			flush(i)
			b.WriteString(".*")
			i += 2
			lit = i
		case pat[i] == '*':
			flush(i)
			b.WriteString("[^/]*")
			i++
			lit = i
		case pat[i] == '?':
			flush(i)
			b.WriteString("[^/]")
			i++
			lit = i
		default:
			i++
		}
	}
	flush(len(pat))
	b.WriteString("$")
	return regexp.MustCompile(b.String())
}

// Hash is the SHA-256 over `<path>\0<sha256 of the file's bytes>\n` for each baseline file in
// path order (`missing` for a file that cannot be read), as lowercase hex: the approval hash.
func Hash(root string, paths []string) string {
	sorted := slices.Clone(paths)
	slices.Sort(sorted)
	var buf bytes.Buffer
	for _, p := range sorted {
		digest := "missing"
		if b, err := os.ReadFile(filepath.Join(root, p)); err == nil {
			sum := sha256.Sum256(b)
			digest = hex.EncodeToString(sum[:])
		}
		buf.WriteString(p + "\x00" + digest + "\n")
	}
	sum := sha256.Sum256(buf.Bytes())
	return hex.EncodeToString(sum[:])
}

// Approval is `.kogen/local/approvals/<slug>.json` (AUT-2).
type Approval struct {
	Slug             string         `json:"slug"`
	SHA256           string         `json:"sha256"`
	Approver         string         `json:"approver"`
	ApprovedAt       string         `json:"approved_at"`
	SourceProvenance map[string]any `json:"source_provenance"`
}

// ApprovalPath is the approval file of an Intent (an absolute path under root).
func ApprovalPath(root, slug string) string {
	return filepath.Join(root, ".kogen/local/approvals/"+slug+".json")
}

// ReadApproval reads the approval of an Intent: nil without an error when there is none, an error
// when the file cannot be read or is not an approval.
func ReadApproval(root, slug string) (*Approval, error) {
	b, err := os.ReadFile(ApprovalPath(root, slug))
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var a Approval
	if err := json.Unmarshal(b, &a); err != nil {
		return nil, fmt.Errorf("approval %s: %w", slug, err)
	}
	return &a, nil
}

// EncodeApproval is the approval file's bytes: the JSON object and a newline.
func EncodeApproval(a Approval) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(a); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil // Encode already ends with a newline
}

// WriteApproval writes the approval file, creating its folder.
func WriteApproval(root string, a Approval) error {
	b, err := EncodeApproval(a)
	if err != nil {
		return err
	}
	path := ApprovalPath(root, a.Slug)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, b, 0o644)
}
