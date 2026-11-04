package tools

import (
	"slices"
	"strings"
	"testing"
)

// TestListAndSearchPrintPathsAsNamed: a real repository's names print as the file system
// spells them, so that the printed path can be passed to read_file.
func TestListAndSearchPrintPathsAsNamed(t *testing.T) {
	t.Parallel()
	_, root := newRepo(t)
	for _, name := range []string{"café.txt", "a b.txt", `back\slash.txt`, "z trailing "} {
		write(t, root, name, "needle here\n")
	}
	tl := newTools(root, ListFilesTool, SearchTextTool, ReadFileTool)
	want := "a b.txt\nback\\slash.txt\ncafé.txt\nz trailing "
	if got := run(t, tl, ListFilesTool, nil); got != want {
		t.Errorf("list: %q, want %q", got, want)
	}
	wantSearch := "a b.txt:1:needle here\nback\\slash.txt:1:needle here\ncafé.txt:1:needle here\nz trailing :1:needle here"
	if got := run(t, tl, SearchTextTool, map[string]any{"pattern": "needle"}); got != wantSearch {
		t.Errorf("search: %q, want %q", got, wantSearch)
	}
	for _, name := range []string{"café.txt", `back\slash.txt`, "z trailing "} {
		if got := run(t, tl, ReadFileTool, map[string]any{"path": name}); got != "1\tneedle here" {
			t.Errorf("read %q: %q", name, got)
		}
	}
}

// TestListAndSearchQuoteWhatCannotBeShownVerbatim: one line per file, strconv.Quote form.
func TestListAndSearchQuoteWhatCannotBeShownVerbatim(t *testing.T) {
	t.Parallel()
	_, root := newRepo(t)
	names := []string{"line\nbreak.txt", "é/tab\there.txt", "q/start\x01.txt", "q/soft\u00adhyphen.txt", "\"quoted.txt", "plain.txt"}
	for _, name := range names {
		write(t, root, name, "needle\n")
	}
	tl := newTools(root, ListFilesTool, SearchTextTool, ReadFileTool)
	want := []string{
		`"\"quoted.txt"`,
		`"line\nbreak.txt"`,
		"\"q/soft\\u00adhyphen.txt\"",
		`"q/start\x01.txt"`,
		"plain.txt",
		`"é/tab\there.txt"`,
	}
	slices.Sort(want)
	gotList := strings.Split(run(t, tl, ListFilesTool, nil), "\n")
	slices.Sort(gotList)
	if !slices.Equal(gotList, want) {
		t.Errorf("list: %q, want %q", gotList, want)
	}
	gotSearch := strings.Split(run(t, tl, SearchTextTool, map[string]any{"pattern": "needle"}), "\n")
	slices.Sort(gotSearch)
	var wantSearch []string
	for _, w := range want {
		wantSearch = append(wantSearch, w+":1:needle")
	}
	slices.Sort(wantSearch)
	if !slices.Equal(gotSearch, wantSearch) {
		t.Errorf("search: %q, want %q", gotSearch, wantSearch)
	}
	if got := run(t, tl, ReadFileTool, map[string]any{"path": "line\nbreak.txt"}); got != "1\tneedle" {
		t.Errorf("read: %q", got)
	}
}

type zRepo struct {
	Git
	files, grep string
}

func (r zRepo) Run(args ...string) (GitResult, error) {
	if args[0] == "ls-files" {
		return GitResult{Stdout: r.files}, nil
	}
	return GitResult{Stdout: r.grep}, nil
}

// TestInvalidUTF8NamesAreQuoted: a name that is not UTF-8 cannot be made on every file
// system, so Git's -z answers come from a fake.
func TestInvalidUTF8NamesAreQuoted(t *testing.T) {
	t.Parallel()
	tl := &Tools{Root: t.TempDir(), Enabled: []string{ListFilesTool, SearchTextTool},
		Repo: zRepo{files: "caf\xe9.txt\x00", grep: "caf\xe9.txt\x001\x00needle\n"}}
	if got := run(t, tl, ListFilesTool, nil); got != `"caf\xe9.txt"` {
		t.Errorf("list: %q", got)
	}
	if got := run(t, tl, SearchTextTool, map[string]any{"pattern": "needle"}); got != `"caf\xe9.txt":1:needle` {
		t.Errorf("search: %q", got)
	}
}

// TestSearchRecordsKeepTheirText: the text of a match may hold NUL and the colon; only the
// last match loses its trailing white space.
func TestSearchRecordsKeepTheirText(t *testing.T) {
	t.Parallel()
	tl := &Tools{Root: t.TempDir(), Enabled: []string{SearchTextTool},
		Repo: zRepo{grep: "a.txt\x001\x00x\x00y: z\nb.txt\x0012\x00last \n"}}
	if got := run(t, tl, SearchTextTool, map[string]any{"pattern": "x|last"}); got != "a.txt:1:x\x00y: z\nb.txt:12:last" {
		t.Errorf("search: %q", got)
	}
}
