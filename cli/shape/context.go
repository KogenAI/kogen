package shape

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"

	"kogen-loop/provider"
	"kogen/agent"
	"kogen/git"
	"kogen/project"
)

// The shaper's context: a deterministic, index-first navigation of the checkout (every file
// with its hash, size, ownership and exact step and declaration signatures) next to the
// authoritative contracts, which are never clipped.

// Signature is a step pattern or a source declaration of a file with its exact line range.
type Signature struct {
	Text               string
	StartLine, EndLine int
}

func (s Signature) json() map[string]any {
	return map[string]any{"text": s.Text, "start_line": s.StartLine, "end_line": s.EndLine}
}

// SignaturePage is where the complete signature list of a file with more than 200 is kept.
type SignaturePage struct {
	Count     int
	Source    string
	SHA256    string
	Retrieval string
}

// ContextEntry is one file of the checkout in the index.
type ContextEntry struct {
	Path      string
	SHA256    string
	Bytes     int
	Ownership string // protected, editable-owned, shared or source
	// Signatures are at most the first 200; SignatureIndex names the page with all of them.
	Signatures     []Signature
	SignatureIndex *SignaturePage
	// Source is the copy of the original bytes of a file shaping is editing ("" for none).
	Source string
}

func (e ContextEntry) json() map[string]any {
	sigs := make([]any, len(e.Signatures))
	for i, s := range e.Signatures {
		sigs[i] = s.json()
	}
	m := map[string]any{"path": e.Path, "sha256": e.SHA256, "bytes": e.Bytes, "ownership": e.Ownership, "signatures": sigs}
	if e.Source != "" {
		m["source"] = e.Source
	}
	if p := e.SignatureIndex; p != nil {
		m["signature_index"] = map[string]any{"count": p.Count, "source": p.Source, "sha256": p.SHA256, "retrieval": p.Retrieval}
	}
	return m
}

// ContextSelection is what of one file the context carries.
type ContextSelection struct {
	Path                                string
	SHA256                              string
	IncludedBodyBytes, OmittedBodyBytes int
	Reason                              string
}

// ContextMeasure is the body bytes the context included and left out.
type ContextMeasure struct {
	Included, Omitted int
	Selection         []ContextSelection
}

// ContextIndex is the navigation index of a checkout.
type ContextIndex struct {
	Root        string
	Revision    Revision
	Entries     []ContextEntry
	Directories []DirectoryCount
	Retrieval   string
	Measure     ContextMeasure
}

// DirectoryCount is the number of files directly in a directory.
type DirectoryCount struct {
	Path  string
	Count int
}

// ContextOptions tune the index.
type ContextOptions struct {
	// Owned are the files shaping may edit; nil means the files of originals.
	Owned []string
	// OriginalDir, when set, is where the original bytes of the files in originals are kept:
	// their entries name that copy as their source.
	OriginalDir string
	// FullPaths are the files whose whole body counts as included; nil means README.md.
	FullPaths []string
}

const signaturePageLimit = 200

const contextRetrieval = "read_file exact bytes and line ranges; list_files directories; search_text exact signatures"

// BuildContextIndex builds the index of the checkout of repo for the Intent slug. originals
// are the original bytes of files shaping already replaced (they are indexed, not the files
// on disk). The text is `Context index: <JSON>\n`, byte for byte what the shaper receives.
func BuildContextIndex(repo *git.Repo, cfg *project.Config, slug string, originals map[string][]byte, opts ContextOptions) (string, *ContextIndex, error) {
	root := repo.Dir
	revision, err := CurrentRevision(repo)
	if err != nil {
		return "", nil, err
	}
	listed, err := repo.OK("ls-files", "--cached", "--others", "--exclude-standard", "-z")
	if err != nil {
		return "", nil, err
	}
	var paths []string
	for _, p := range strings.Split(listed, "\x00") {
		if p != "" {
			paths = append(paths, p)
		}
	}
	sort.Strings(paths)
	paths = slices.Compact(paths)

	protected, err := project.Protected(root, cfg)
	if err != nil {
		return "", nil, err
	}
	var acceptance []string
	if project.IntentExists(root, slug) {
		if intent, err := project.LoadIntent(root, slug); err == nil {
			acceptance = intent.Acceptance
		}
	}
	owned := opts.Owned
	if owned == nil {
		for p := range originals {
			owned = append(owned, p)
		}
	}
	stepsDir := ""
	if cfg.Acceptance != nil {
		stepsDir = cfg.Acceptance.StepsDir
	}

	var entries []ContextEntry
	for _, path := range paths {
		if strings.HasPrefix(path, ".kogen/local/") || filepath.Base(path) == "AGENTS.md" || filepath.Base(path) == "CLAUDE.md" {
			continue
		}
		if st, err := os.Stat(filepath.Join(root, path)); err != nil || !st.Mode().IsRegular() {
			continue
		}
		bytes, ok := originals[path]
		if !ok {
			if bytes, err = os.ReadFile(filepath.Join(root, path)); err != nil {
				return "", nil, err
			}
		}
		e := ContextEntry{Path: path, SHA256: ContentHash(bytes), Bytes: len(bytes)}
		switch {
		case slices.Contains(protected, path):
			e.Ownership = "protected"
		case slices.Contains(owned, path):
			e.Ownership = "editable-owned"
		case slices.Contains(acceptance, path):
			e.Ownership = "shared"
		case stepsDir != "" && strings.HasPrefix(path, stepsDir+"/"):
			e.Ownership = "shared"
		default:
			e.Ownership = "source"
		}
		if strings.HasSuffix(path, ".js") || strings.HasSuffix(path, ".qnt") || strings.HasSuffix(path, ".ex") {
			e.Signatures = signatures(bytes)
		}
		if _, isOriginal := originals[path]; isOriginal && opts.OriginalDir != "" {
			e.Source = filepath.Join(opts.OriginalDir, path)
		}
		entries = append(entries, e)
	}

	for i := range entries {
		e := &entries[i]
		if len(e.Signatures) <= signaturePageLimit {
			continue
		}
		var lines []string
		for _, s := range e.Signatures {
			b, err := project.EncodeJSON(s.json())
			if err != nil {
				return "", nil, err
			}
			lines = append(lines, string(b))
		}
		text := strings.Join(lines, "\n")
		dest := filepath.Join(root, ".kogen/local/context", e.SHA256+"-signatures.json")
		if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
			return "", nil, err
		}
		if err := os.WriteFile(dest, []byte(text), 0o666); err != nil {
			return "", nil, err
		}
		e.SignatureIndex = &SignaturePage{
			Count: len(e.Signatures), Source: dest, SHA256: ContentHash([]byte(text)),
			Retrieval: "read_file with start_line/end_line; search_text source declarations",
		}
		e.Signatures = e.Signatures[:signaturePageLimit]
	}

	full := opts.FullPaths
	if full == nil {
		full = []string{"README.md"}
	}
	var measure ContextMeasure
	for _, e := range entries {
		included := 0
		reason := "index and exact retrieval only"
		if slices.Contains(full, e.Path) {
			included = e.Bytes
			reason = "full authoritative contract; exact instructions/declarations win excerpt budget"
		}
		measure.Included += included
		measure.Omitted += e.Bytes - included
		measure.Selection = append(measure.Selection, ContextSelection{e.Path, e.SHA256, included, e.Bytes - included, reason})
	}

	counts := map[string]int{}
	for _, p := range paths {
		counts[filepath.Dir(p)]++
	}
	var dirs []DirectoryCount
	var dirList []any
	for _, d := range sortedKeys(counts) {
		dirs = append(dirs, DirectoryCount{d, counts[d]})
		dirList = append(dirList, map[string]any{"path": d, "count": counts[d]})
	}
	idx := &ContextIndex{Root: root, Revision: revision, Entries: entries, Directories: dirs, Retrieval: contextRetrieval, Measure: measure}

	entryList := make([]any, len(entries))
	for i, e := range entries {
		entryList[i] = e.json()
	}
	doc, err := project.EncodeJSON(map[string]any{
		"root": root, "revision": revision.Map(), "entries": entryList, "directories": dirList, "retrieval": contextRetrieval,
	})
	if err != nil {
		return "", nil, err
	}
	return "Context index: " + string(doc) + "\n", idx, nil
}

// patterns that open a step definition: its literal pattern is kept with its lines.
var stepPattern = regexp.MustCompile(`(?:^|\n)[ \t]*(?:Given|When|Then|defineStep)\s*\(\s*(?:'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*"|/(?:[^/\\]|\\.)*/[a-z]*)`)

var declarationPattern = regexp.MustCompile(`^\s*(module |var |val |action |def )`)

// signatures keeps the literal multi-line step patterns and the relevant source declarations
// of a file, in line order.
func signatures(bytes []byte) []Signature {
	text := string(bytes)
	var out []Signature
	for _, m := range stepPattern.FindAllStringIndex(text, -1) {
		offset, size := m[0], m[1]-m[0]
		matched := strings.TrimLeft(text[offset:offset+size], "\n")
		start := 1 + strings.Count(text[:offset], "\n")
		if text[offset] == '\n' {
			start++
		}
		out = append(out, Signature{Text: matched, StartLine: start, EndLine: start + strings.Count(matched, "\n")})
	}
	for i, line := range strings.Split(text, "\n") {
		if declarationPattern.MatchString(line) {
			out = append(out, Signature{Text: line, StartLine: i + 1, EndLine: i + 1})
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].StartLine < out[j].StartLine })
	return out
}

const excerptBytes = 8192

// Excerpt is an explicit window of a file: at most 80 lines and 8192 bytes, starting five
// lines before the first line that mentions a term (the first lines without a match). The
// header names the exact path, hash and 1-based line range. The shaper's context carries none
// automatically; this is the window an index entry can be expanded to.
func Excerpt(path, sha256, bytes string, terms []string) string {
	lines := strings.Split(bytes, "\n")
	if lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	first := 0
	for i, l := range lines {
		lower := strings.ToLower(l)
		if slices.ContainsFunc(terms, func(t string) bool { return strings.Contains(lower, t) }) {
			first = i
			break
		}
	}
	start := max(0, first-5)
	var body strings.Builder
	for i := start; i < len(lines) && i < start+80; i++ {
		if body.Len()+len(lines[i])+1 > excerptBytes {
			break
		}
		body.WriteString(lines[i] + "\n")
	}
	text := body.String()
	header, _ := project.EncodeJSON(map[string]any{
		"path": path, "sha256": sha256, "start_line": start + 1,
		"end_line": start + max(0, strings.Count(text, "\n")),
	})
	return "Excerpt: " + string(header) + "\n" + text
}

// ExcerptOf is Excerpt for an index entry.
func ExcerptOf(e ContextEntry, bytes string, terms []string) string {
	return Excerpt(e.Path, e.SHA256, bytes, terms)
}

// contextGuidance is the closing paragraph of the shaper's instructions.
func contextGuidance() string { return agent.Prompt(agent.ShaperContextGuidance) }

// ShaperInstructions is the shaper's policy: its instructions and the context guidance.
func ShaperInstructions() string { return agent.Prompt(agent.Shaper) + contextGuidance() }

// selectionEvent is the context_selection event of one request: what the context carried,
// the size of the whole conversation input and the references retained for the proposal.
func selectionEvent(input []any, manifest any, m ContextMeasure) (map[string]any, error) {
	enc, err := project.EncodeJSON(input)
	if err != nil {
		return nil, err
	}
	selection := make([]any, len(m.Selection))
	for i, s := range m.Selection {
		selection[i] = map[string]any{
			"path": s.Path, "sha256": s.SHA256, "included_body_bytes": s.IncludedBodyBytes,
			"omitted_body_bytes": s.OmittedBodyBytes, "reason": s.Reason,
		}
	}
	return map[string]any{
		"event": "context_selection", "selection": selection, "supplied_input_bytes": len(enc),
		"retained_references": manifest, "included_body_bytes": m.Included, "omitted_body_bytes": m.Omitted,
		"full_contract_reasons": []any{"Active request, README, testing rules, protection, Intent prose, Gherkin and model declarations are authoritative and are not clipped."},
	}, nil
}

// ---- the first message ----

// promptInput is what the first message of a shaping conversation is made of.
type promptInput struct {
	root, slug string
	cfg        *project.Config
	state      *state
	protected  []string
	selected   string // the context index text
}

// contextBlocks is the shaper's first message content: the stable contract text and the
// dynamic navigation index, as two input_text blocks.
func contextBlocks(p promptInput) ([]any, error) {
	stepsDir := ""
	runCommand := ""
	if p.cfg.Acceptance != nil {
		stepsDir, runCommand = p.cfg.Acceptance.StepsDir, p.cfg.Acceptance.Run
	}
	baseline, err := project.Baseline(p.root, p.slug, p.cfg)
	if err != nil {
		return nil, err
	}
	var acceptancePaths []string
	if project.IntentExists(p.root, p.slug) {
		if intent, err := project.LoadIntent(p.root, p.slug); err == nil {
			acceptancePaths = intent.Acceptance
		}
	}
	var automatic []string
	for _, path := range baseline {
		if path == project.ConfigPath || slices.Contains(acceptancePaths, path) || strings.HasPrefix(path, project.IntentDir(p.slug)+"/") {
			automatic = append(automatic, path)
		}
	}

	var rounds []string
	for n, r := range p.state.Rounds {
		var qa []string
		answers := answersOf(r)
		for i, q := range questionsOf(r) {
			var opts strings.Builder
			for k, o := range optionsOf(q) {
				fmt.Fprintf(&opts, "\n   %c) %s", 'a'+k, textOf(o["label"]))
			}
			qa = append(qa, fmt.Sprintf("%d. %s%s\n   answer: %d: %s", i+1, textOf(q["question"]), opts.String(), i+1, textOf(answers[fmt.Sprint(i+1)])))
		}
		rounds = append(rounds, fmt.Sprintf("Round %d:\n%s", n+1, strings.Join(qa, "\n")))
	}
	roundText := strings.Join(rounds, "\n")

	var checks []string
	for _, c := range p.cfg.Checks {
		checks = append(checks, c.Name+": "+c.Run)
	}
	stepsText := stepsDir
	if stepsDir == "" {
		stepsText = "(commands.acceptance.steps_dir is unset: you cannot add step files)"
	}

	var b strings.Builder
	b.WriteString("# Request\n\n" + p.state.Request + "\n\n")
	if roundText != "" {
		b.WriteString("# Your earlier questions and the caller's answers (cite them as `(source: answer <n>)` using the numbers of the latest round)\n\n" + roundText + "\n")
	}
	b.WriteString("\n# The Intent to write\n\n")
	fmt.Fprintf(&b, "Slug: %s\nWrite `%s`, `%s`, optionally `%s`, and step files under `%s/`.\n\n", p.slug,
		project.IntentMDPath(p.slug), project.FeaturePath(p.slug), project.ModelPath(p.slug), stepsText)
	b.WriteString("# Project instructions (README.md)\n\n" + ReadmeText(p.root) + "\n\n")
	b.WriteString("# Testing rules (docs/testing-rules.md)\n\n" + agent.Prompt(agent.TestingRules) + "\n\n")
	b.WriteString("# Configured commands (.kogen/project.yaml)\n\n")
	fmt.Fprintf(&b, "setup: %s\nfix: %s\nchecks: %s\nacceptance: %s\n", InspectStrings(p.cfg.Setup), InspectStrings(p.cfg.Fix), strings.Join(checks, ", "), runCommand)
	b.WriteString("  (it runs with KOGEN_ACCEPTANCE_FEATURES set to the Intent's feature path and KOGEN_ACCEPTANCE_REPORT to the report path)\n\n")
	b.WriteString("# Protection contract\n\n")
	fmt.Fprintf(&b, "configured protect patterns: %s\npaths currently matched by those patterns: %s\n", InspectStrings(p.cfg.Protect), InspectStrings(p.protected))
	fmt.Fprintf(&b, "automatic baseline: every file in `%s/`, every path listed under the Intent's `Acceptance:` (including step files), and `.kogen/project.yaml`.\n", project.IntentDir(p.slug))
	fmt.Fprintf(&b, "automatic paths currently present or listed: %s\n", InspectStrings(automatic))
	b.WriteString("Approval freezes this baseline. It is not an exception or authorization to change a protected path. Inspect the implementation edits required to deliver the requested outcome; do not infer a conflict by scanning request prose. If a required protected edit cannot be avoided without changing the requested outcome, submit the exclusive `blocked` report with actual protected paths and a reason. Never submit a ready package conditional on a protected-edit approval mechanism: no such override exists.\n\n")
	b.WriteString("Full contract inclusions: exact request, Q&A, README, testing rules and protection/automatic baseline are authoritative and are not clipped.\n")
	return provider.ContractBlocks(b.String(), p.selected), nil
}
