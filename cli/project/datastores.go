package project

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"

	kgit "kogen/git"
)

// The `## Data stores` section of intent.md: where an entity's data lives. The scan of the
// files tracked at a commit that reference a declared key is model-free and shared by Shape,
// which refuses a candidate whose section leaves a referencing file uncovered, and by the
// Build's independent review, which receives it as evidence.

const dataStoresHeader = "## Data stores"

var (
	dataStoreKeyRe      = regexp.MustCompile("^- key `([^`\\s]+)`$")
	dataStoreScopeRe    = regexp.MustCompile("^- `([^`]+)`: in scope, observed by `([^`]+)`$")
	dataStoreExcludedRe = regexp.MustCompile("^- `([^`]+)`: excluded by decision ([1-9][0-9]*)$")
)

// DataStoreItem is one valid-form item line of the section.
type DataStoreItem struct {
	Line     string // the line as written
	Path     string
	Excluded bool
	Text     string // the observation text of an in-scope item
	Decision string // the decision number of an excluded item, as written
}

// covers reports whether the item's path matches the file.
func (it DataStoreItem) covers(file string) bool {
	if strings.HasSuffix(it.Path, "/") {
		return strings.HasPrefix(file, it.Path)
	}
	return file == it.Path
}

// DataStoreReference is one file that references one declared key.
type DataStoreReference struct {
	File, Key string
	Lines     []int
	// Cover is the covering item line without its leading "- "; "" when none covers it.
	Cover string
}

// DataStoresReport is the section of an Intent checked against the files tracked at a commit.
type DataStoresReport struct {
	Keys         []string
	NotItems     []string // lines that are none of the three forms
	ItemProblems []string // one line per invalid item
	References   []DataStoreReference
}

// ScanDataStores checks the Intent's `## Data stores` section against the files tracked at
// commit. The bool is false, with no report, when the Intent has no such section. Acceptance
// files are read from the checkout the Intent was read from.
func ScanDataStores(repo *kgit.Repo, commit string, intent *Intent) (*DataStoresReport, bool, error) {
	lines := strings.Split(intent.Text, "\n")
	if _, ok := afterHeader(lines, dataStoresHeader); !ok {
		return nil, false, nil
	}
	r := &DataStoresReport{}
	var items []DataStoreItem
	for _, l := range sectionBullets(lines, dataStoresHeader) {
		switch {
		case dataStoreKeyRe.MatchString(l):
			if key := dataStoreKeyRe.FindStringSubmatch(l)[1]; !slices.Contains(r.Keys, key) {
				r.Keys = append(r.Keys, key)
			}
		case dataStoreScopeRe.MatchString(l):
			m := dataStoreScopeRe.FindStringSubmatch(l)
			items = append(items, DataStoreItem{Line: l, Path: m[1], Text: m[2]})
		case dataStoreExcludedRe.MatchString(l):
			m := dataStoreExcludedRe.FindStringSubmatch(l)
			items = append(items, DataStoreItem{Line: l, Path: m[1], Excluded: true, Decision: m[2]})
		default:
			r.NotItems = append(r.NotItems, "- not a ## Data stores item: "+l)
		}
	}
	entries, err := repo.TreeEntries(commit)
	if err != nil {
		return nil, true, err
	}
	tracked := make([]string, len(entries))
	for i, e := range entries {
		tracked[i] = e.Path
	}
	acceptance := acceptanceTexts(intent)
	var valid []DataStoreItem
	for _, it := range items {
		if problem := it.problem(tracked, acceptance, intent.Decisions); problem != "" {
			r.ItemProblems = append(r.ItemProblems, "- "+it.Path+": "+problem)
			continue
		}
		valid = append(valid, it)
	}
	refs, err := dataStoreReferences(repo, commit, r.Keys)
	if err != nil {
		return nil, true, err
	}
	for i := range refs {
		for _, it := range valid {
			if it.covers(refs[i].File) {
				refs[i].Cover = strings.TrimPrefix(it.Line, "- ")
				break
			}
		}
	}
	r.References = refs
	return r, true, nil
}

// acceptanceTexts is the contents on disk of acceptance.feature and the step files listed
// under Acceptance; a file that cannot be read contributes nothing.
func acceptanceTexts(intent *Intent) []string {
	var out []string
	for _, p := range append([]string{FeaturePath(intent.Slug)}, intent.StepFiles()...) {
		if b, err := os.ReadFile(filepath.Join(intent.Root, p)); err == nil {
			out = append(out, string(b))
		}
	}
	return out
}

// problem is the item's first failing validity condition, or "" for a valid item.
func (it DataStoreItem) problem(tracked, acceptance, decisions []string) string {
	matched := false
	for _, f := range tracked {
		if it.covers(f) {
			matched = true
			break
		}
	}
	if !matched {
		return "no file tracked at HEAD has this path"
	}
	if !it.Excluded {
		for _, t := range acceptance {
			if strings.Contains(t, it.Text) {
				return ""
			}
		}
		return "acceptance.feature and the step files listed under Acceptance do not contain " + it.Text
	}
	n, err := strconv.Atoi(it.Decision)
	if err != nil || n > len(decisions) {
		return "## Decisions has no line " + it.Decision
	}
	if !strings.Contains(decisions[n-1], it.Path) {
		return "decision " + it.Decision + " does not name " + it.Path
	}
	return ""
}

// dataStoreReferences are the files tracked at commit, outside .kogen/, that contain a key as
// a whole word, with the numbers of the lines that contain it: what
// `git grep -I -n -w -F -e <key> <commit> -- . ':(exclude).kogen'` reports, ordered by file
// path (byte order), then by key order.
func dataStoreReferences(repo *kgit.Repo, commit string, keys []string) ([]DataStoreReference, error) {
	byFile := map[string]map[string][]int{}
	for _, key := range keys {
		res, err := repo.Run("grep", "-z", "-I", "-n", "-w", "-F", "--no-color", "-e", key, commit, "--", ".", ":(exclude).kogen")
		if err != nil {
			return nil, err
		}
		if res.Status == 1 && res.Stdout == "" {
			continue
		}
		if res.Status != 0 {
			return nil, fmt.Errorf("git grep for %q failed (status %d): %s", key, res.Status, strings.TrimSpace(res.Stderr))
		}
		out := res.Stdout
		for out != "" {
			name, rest, ok := strings.Cut(out, "\x00")
			if !ok {
				break
			}
			number, rest, ok := strings.Cut(rest, "\x00")
			if !ok {
				break
			}
			_, rest, _ = strings.Cut(rest, "\n")
			out = rest
			file, ok := strings.CutPrefix(name, commit+":")
			n, err := strconv.Atoi(number)
			if !ok || err != nil {
				return nil, fmt.Errorf("git grep: unexpected record %q", name)
			}
			if byFile[file] == nil {
				byFile[file] = map[string][]int{}
			}
			byFile[file][key] = append(byFile[file][key], n)
		}
	}
	files := make([]string, 0, len(byFile))
	for f := range byFile {
		files = append(files, f)
	}
	sort.Strings(files)
	var refs []DataStoreReference
	for _, f := range files {
		for _, key := range keys {
			if lines, ok := byFile[f][key]; ok {
				sort.Ints(lines)
				refs = append(refs, DataStoreReference{File: f, Key: key, Lines: lines})
			}
		}
	}
	return refs, nil
}

// lineList is `(line 1)` for one line and `(lines 1, 4)` for several.
func lineList(lines []int) string {
	parts := make([]string, len(lines))
	for i, n := range lines {
		parts[i] = strconv.Itoa(n)
	}
	if len(parts) == 1 {
		return "(line " + parts[0] + ")"
	}
	return "(lines " + strings.Join(parts, ", ") + ")"
}

func (r DataStoreReference) head() string {
	return "- " + r.File + " references " + r.Key + " " + lineList(r.Lines)
}

// Problems are the lines of the Shape refusal, in order: no key, lines that are no item,
// invalid items, uncovered references.
func (r *DataStoresReport) Problems() []string {
	var out []string
	if len(r.Keys) == 0 {
		out = append(out, "- ## Data stores declares no key")
	}
	out = append(out, r.NotItems...)
	out = append(out, r.ItemProblems...)
	for _, ref := range r.References {
		if ref.Cover == "" {
			out = append(out, ref.head()+"; no ## Data stores item covers it")
		}
	}
	return out
}

// ReferenceLines is one line per reference with its covering item, or the single line
// `- none`.
func (r *DataStoresReport) ReferenceLines() []string {
	if len(r.References) == 0 {
		return []string{"- none"}
	}
	out := make([]string, len(r.References))
	for i, ref := range r.References {
		if ref.Cover == "" {
			out[i] = ref.head() + ": not covered"
		} else {
			out[i] = ref.head() + ": covered by " + ref.Cover
		}
	}
	return out
}

// UncoveredFiles are the distinct files with at least one uncovered reference, in path order.
func (r *DataStoresReport) UncoveredFiles() []string {
	var out []string
	for _, ref := range r.References {
		if ref.Cover == "" && (len(out) == 0 || out[len(out)-1] != ref.File) {
			out = append(out, ref.File)
		}
	}
	return out
}

// DataStoresHeadline is the first line of the Shape refusal of n problems.
func DataStoresHeadline(n int) string {
	return fmt.Sprintf("Data stores: %d problem(s) with where the data of the declared keys lives; nothing was published. "+
		"Every file tracked at HEAD that references a key declared under ## Data stores needs an item that covers it: in scope, observed by text that acceptance.feature or a listed step file contains, or excluded by a numbered Decision that names it. "+
		"Resubmitting this candidate unchanged is refused again.", n)
}

// DataStoresEvidence is the review authority's Data stores block, ending with a blank line;
// "" when the section declares no key.
func (r *DataStoresReport) DataStoresEvidence() string {
	if len(r.Keys) == 0 {
		return ""
	}
	return "# Data stores\n\n" +
		"Keys declared under the approved Intent's ## Data stores: " + strings.Join(r.Keys, ", ") + "\n" +
		"Files tracked at the Build's start commit that reference a declared key, and the item that covers each:\n" +
		strings.Join(r.ReferenceLines(), "\n") + "\n" +
		"A file that is not covered holds or reaches data the approved Intent neither scopes nor excludes by a Decision: report a blocking finding at its path. " +
		"You cannot change the approved Intent; Kogen refuses a verdict without that finding.\n\n"
}
