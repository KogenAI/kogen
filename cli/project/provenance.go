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
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"

	"kogen-loop/sys"
	kgit "kogen/git"
)

// Source provenance: the private receipt of a successful Shape under
// `.kogen/local/provenance/<slug>/current.json` (version 1). It holds the request, the
// questions asked and the answers given, the corrections of later Refines, the complete
// protected contract's hash and the Intent's Source comparison. It is diagnostic data, never
// authority: an approval binds the receipt by path and hash, and every use re-validates its
// custody (directories 0700, files 0600, no symbolic links, bytes equal to the hash).
// Earlier receipts stay as immutable archives named by their hash.

const comparisonLimit = 8192

// SourceRef binds one receipt file: its path and the SHA-256 of its bytes, and, for the
// current receipt, the contract hash it was bound to. It is the `source_provenance` of an
// approval. Archive references carry no contract hash.
type SourceRef struct {
	Path           string `json:"path"`
	SHA256         string `json:"sha256"`
	ContractSHA256 string `json:"contract_sha256,omitempty"`
}

// Map is the reference as the JSON object an approval records.
func (r *SourceRef) Map() map[string]any {
	if r == nil {
		return nil
	}
	m := map[string]any{"path": r.Path, "sha256": r.SHA256}
	if r.ContractSHA256 != "" {
		m["contract_sha256"] = r.ContractSHA256
	}
	return m
}

// SourceRefFromMap reads a reference from an approval's `source_provenance` object: nil for
// no object (a legacy approval). A missing or non-string member reads as empty, which
// ValidateSource refuses.
func SourceRefFromMap(m map[string]any) *SourceRef {
	if m == nil {
		return nil
	}
	str := func(k string) string { s, _ := m[k].(string); return s }
	return &SourceRef{Path: str("path"), SHA256: str("sha256"), ContractSHA256: str("contract_sha256")}
}

// Equal reports whether two references (either may be nil) are the same binding.
func (r *SourceRef) Equal(o *SourceRef) bool {
	if r == nil || o == nil {
		return r == o
	}
	return *r == *o
}

// SourceRequest is a request as the receipt records it: its exact text, where it came from
// (`-` for standard input) and its SHA-256. A Refine correction is recorded the same way.
type SourceRequest struct {
	Text       string `json:"text"`
	SourcePath string `json:"source_path"`
	SHA256     string `json:"sha256"`
}

// NewSourceRequest records text read from path; an empty path means standard input (`-`).
func NewSourceRequest(text, path string) SourceRequest {
	if path == "" {
		path = "-"
	}
	return SourceRequest{Text: text, SourcePath: path, SHA256: sha256Hex([]byte(text))}
}

// SourceOrigin is where a Shape started: HEAD, the candidate tree and a digest of the
// project configuration.
type SourceOrigin struct {
	Head          string `json:"head"`
	Tree          string `json:"tree"`
	Configuration string `json:"configuration"`
}

// CaptureOrigin records the origin of a Shape at root: HEAD, the tree of the checkout as it
// is now (tracked and not-ignored untracked files) and the configuration digest.
func CaptureOrigin(root string, cfg *Config) (SourceOrigin, error) {
	repo := kgit.New(root, nil)
	head := repo.Head()
	if head == "" {
		return SourceOrigin{}, fmt.Errorf("source origin: %s has no commit", root)
	}
	tree, err := repo.Tree(head, nil)
	if err != nil {
		return SourceOrigin{}, fmt.Errorf("source origin: %w", err)
	}
	return SourceOrigin{Head: head, Tree: tree, Configuration: configDigest(cfg)}, nil
}

// ShapeSource is what a successful Shape hands to CaptureSource: the shaping state it kept
// while it ran. Rounds are the rounds' JSON objects as shaping saved them (`questions`, a list
// of objects with optional `options`, and `answers`, a map from the question number to the
// text the caller gave), kept whole so the receipt records exactly what was asked.
type ShapeSource struct {
	Request    string
	SourcePath string // empty: standard input
	Rounds     []map[string]any
	Origin     SourceOrigin
}

// SourcePath is the current receipt of an Intent.
func SourcePath(root, slug string) string {
	return filepath.Join(root, ".kogen/local/provenance/"+slug+"/current.json")
}

var comparisonHeading = regexp.MustCompile(`(?m)^## Source comparison[^\S\n]*\n`)

func comparisonRequired() *sys.Error {
	return sys.Fail("intent", "lint",
		"the Intent needs a nonempty ## Source comparison of at most 8192 UTF-8 bytes; compare behaviors and settled non-secret literals with source/contract references, without raw originals or secrets", 1)
}

// SourceComparison is the trimmed body of the Intent's `## Source comparison` section: the
// text up to the next `## ` heading or the end of the file. It is an `intent/lint` error
// (exit 1) when the section is missing, empty or longer than 8192 bytes; a long report is
// never clipped.
func SourceComparison(root, slug string) (string, error) {
	b, err := os.ReadFile(filepath.Join(root, IntentMDPath(slug)))
	if err != nil {
		return "", err
	}
	text := string(b)
	loc := comparisonHeading.FindStringIndex(text)
	if loc == nil {
		return "", comparisonRequired()
	}
	body := text[loc[1]:]
	if i := strings.Index(body, "\n## "); i >= 0 {
		body = body[:i]
	}
	body = strings.TrimSpace(body)
	if body == "" || len(body) > comparisonLimit {
		return "", comparisonRequired()
	}
	return body, nil
}

// CaptureSource publishes the receipt of a successful Shape: version 1 with the request,
// the rounds with their resolved answers, no corrections, the origin, the hash of the
// complete protected contract and the Intent's Source comparison.
func CaptureSource(root, slug string, cfg *Config, st ShapeSource) error {
	if !utf8.ValidString(st.Request) {
		return errors.New("source provenance: the request is not valid UTF-8")
	}
	rounds := make([]any, len(st.Rounds))
	for i, r := range st.Rounds {
		resolved, err := resolveRound(r)
		if err != nil {
			return err
		}
		rounds[i] = resolved
	}
	paths, err := Baseline(root, slug, cfg)
	if err != nil {
		return err
	}
	comparison, err := SourceComparison(root, slug)
	if err != nil {
		return err
	}
	return PublishSource(root, slug, map[string]any{
		"version":         json.Number("1"),
		"request":         NewSourceRequest(st.Request, st.SourcePath),
		"rounds":          rounds,
		"corrections":     []any{},
		"origin":          st.Origin,
		"contract_sha256": Hash(root, paths),
		"comparison":      comparison,
	})
}

// resolveRound copies a round and adds `resolved_answers`: each answer that is a single
// letter a-z picks the option at that position of its question (its label), any other answer
// stays as typed. Question numbers count from 1; like Elixir's Enum.at, 0 and negative numbers
// count from the end.
func resolveRound(round map[string]any) (map[string]any, error) {
	answers, ok := round["answers"].(map[string]any)
	if !ok {
		return nil, errors.New("source provenance: a round has no answers")
	}
	questions, _ := round["questions"].([]any)
	resolved := make(map[string]any, len(answers))
	for n, raw := range answers {
		answer, ok := raw.(string)
		if !ok {
			return nil, fmt.Errorf("source provenance: answer %s is not text", n)
		}
		num, err := strconv.Atoi(n)
		if err != nil && !errors.Is(err, strconv.ErrRange) {
			return nil, fmt.Errorf("source provenance: answer number %q is not an integer", n)
		}
		var question any
		if err == nil {
			question = enumAt(questions, num-1)
		}
		var text any = answer
		if singleLetter(answer) {
			options, err := optionsOf(question)
			if err != nil {
				return nil, err
			}
			if option := enumAt(options, int(answer[0]-'a')); option != nil && option != false {
				m, ok := option.(map[string]any)
				if !ok {
					return nil, errors.New("source provenance: an option is not an object")
				}
				text = m["label"]
			}
		}
		resolved[n] = text
	}
	out := make(map[string]any, len(round)+1)
	for k, v := range round {
		out[k] = v
	}
	out["resolved_answers"] = resolved
	return out, nil
}

// singleLetter is Elixir's ~r/^[a-z]$/: one letter, optionally followed by a final newline.
func singleLetter(s string) bool {
	return len(s) > 0 && s[0] >= 'a' && s[0] <= 'z' && (len(s) == 1 || s == s[:1]+"\n")
}

func optionsOf(question any) ([]any, error) {
	switch q := question.(type) {
	case nil:
		return nil, nil
	case map[string]any:
		switch o := q["options"].(type) {
		case nil:
			return nil, nil
		case []any:
			return o, nil
		}
	}
	return nil, errors.New("source provenance: a question's options are not a list")
}

func enumAt(list []any, i int) any {
	if i < 0 {
		i += len(list)
	}
	if i < 0 || i >= len(list) {
		return nil
	}
	return list[i]
}

// PublishSource makes doc the current receipt of the Intent. The directories are 0700 and the
// file 0600. A previous current receipt is first kept, byte for byte, as an archive named by
// its SHA-256; an archive that exists must itself be intact, else the publication is refused
// and the current receipt stays. The new receipt replaces the old atomically.
func PublishSource(root, slug string, doc map[string]any) error {
	data, err := EncodeJSON(doc)
	if err != nil {
		return err
	}
	data = append(data, '\n')
	p := SourcePath(root, slug)
	dir := filepath.Dir(p)
	if err := os.MkdirAll(dir, 0o777); err != nil {
		return err
	}
	for _, d := range []string{filepath.Dir(dir), dir} {
		if err := os.Chmod(d, 0o700); err != nil {
			return err
		}
	}
	old, err := os.ReadFile(p)
	switch {
	case err == nil:
		sum := sha256Hex(old)
		archive := filepath.Join(dir, sum+".json")
		if _, err := os.Lstat(archive); errors.Is(err, fs.ErrNotExist) {
			if err := privateWrite(archive, old); err != nil {
				return err
			}
		} else if err := ValidateSource(&SourceRef{Path: archive, SHA256: sum}); err != nil {
			return err
		}
	case errors.Is(err, fs.ErrNotExist):
	default:
		return refuseSource(p)
	}
	tmp := p + ".tmp"
	os.Remove(tmp) // left by an interrupted publication; never a symlink target
	if err := privateWrite(tmp, data); err != nil {
		return err
	}
	if err := os.Rename(tmp, p); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

// privateWrite creates path (it must not exist) with mode 0600 and syncs its bytes.
func privateWrite(path string, data []byte) error {
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

// BindSource returns the reference to the current receipt when it is a version 1 receipt
// and its custody is intact; nil without an error when the Intent has no receipt (a legacy
// Intent: no receipt file and no provenance folder). The receipt may be bound to an earlier
// contract than the current one: a contract changed by Refine or by hand leaves the old
// receipt readable, and the approval card carries it forward as a historical receipt. A
// receipt that exists but is unreadable or not version 1, or a provenance folder without
// one, is refused, never read as absence.
func BindSource(root, slug string) (*SourceRef, error) {
	p := SourcePath(root, slug)
	b, err := os.ReadFile(p)
	if errors.Is(err, fs.ErrNotExist) {
		if _, err := os.Lstat(filepath.Dir(p)); errors.Is(err, fs.ErrNotExist) {
			return nil, nil
		}
		return nil, refuseSource(p)
	}
	if err != nil || !utf8.Valid(b) {
		return nil, refuseSource(p)
	}
	doc, err := decodeJSON(b)
	m, ok := doc.(map[string]any)
	if err != nil || !ok {
		return nil, refuseSource(p)
	}
	if v, ok := m["version"].(json.Number); !ok || v != "1" {
		return nil, refuseSource(p)
	}
	contract, ok := m["contract_sha256"].(string)
	if !ok {
		return nil, refuseSource(p)
	}
	ref := &SourceRef{Path: p, SHA256: sha256Hex(b), ContractSHA256: contract}
	if err := ValidateSource(ref); err != nil {
		return nil, err
	}
	return ref, nil
}

var sha256Pattern = regexp.MustCompile(`\A[0-9a-f]{64}\z`)

// Archived is the reference to the hash-named archive of this receipt beside the current
// one, where a refresh or a Refine keeps what it replaces (nil stays nil).
func (r *SourceRef) Archived() *SourceRef {
	if r == nil {
		return nil
	}
	moved := *r
	moved.Path = filepath.Join(filepath.Dir(r.Path), r.SHA256+".json")
	return &moved
}

// ResolveApproval resolves the source receipt an existing approval marker points at. A
// stale marker's pointer may have been displaced by a later refresh: it is then resolved
// only by its pinned digest in the hash-named history beside the current receipt. The
// marker must point at the current path with a SHA-256 digest; when it still authorizes the
// current contract its pointer must validate as it stands. The current receipt itself must
// bind. A nil approval, or one without a receipt (legacy), resolves to nil.
func ResolveApproval(root, slug string, approval *Approval) (*SourceRef, error) {
	if approval == nil || approval.SourceProvenance == nil {
		return nil, nil
	}
	ref := SourceRefFromMap(approval.SourceProvenance)
	current := SourcePath(root, slug)
	if ref.Path != current || !sha256Pattern.MatchString(ref.SHA256) {
		return nil, refuseSource(current)
	}
	cfg, err := LoadConfig(root)
	if err != nil {
		return nil, err
	}
	baseline, err := Baseline(root, slug, cfg)
	if err != nil {
		return nil, err
	}
	if approval.SHA256 == Hash(root, baseline) {
		if err := ValidateSource(ref); err != nil {
			return nil, err
		}
	}
	resolved := ref
	if b, err := os.ReadFile(current); err != nil || sha256Hex(b) != ref.SHA256 {
		resolved = ref.Archived()
	}
	if err := ValidateSource(resolved); err != nil {
		return nil, err
	}
	if bound, err := BindSource(root, slug); err != nil {
		return nil, err
	} else if bound == nil {
		return nil, refuseSource(current)
	}
	return resolved, nil
}

// transition is the receipt that follows source when the contract changes to sha: the
// predecessor is named by its hash-named archive and the contract it bound.
func transition(doc map[string]any, source *SourceRef, sha string) {
	previous := source.Archived()
	doc["previous_receipt"] = previous.Map()
	doc["prior_contract_sha256"] = source.ContractSHA256
	doc["contract_sha256"] = sha
}

// RefreshSource moves the current receipt to the contract hash sha when it binds another:
// request, rounds, corrections, origin and comparison stay exactly, the predecessor is kept
// as its hash-named archive and named in `previous_receipt`. A receipt that already binds sha
// is returned unchanged. source is the receipt the caller read; custody must still hold and the
// receipt must still be that one. A nil source (legacy) stays nil.
func RefreshSource(root, slug, sha string, source *SourceRef) (*SourceRef, error) {
	if err := ValidateSource(source); err != nil {
		return nil, err
	}
	now, err := BindSource(root, slug)
	if err != nil {
		return nil, err
	}
	if !now.Equal(source) {
		return nil, refuseSource(SourcePath(root, slug))
	}
	if source != nil && source.ContractSHA256 != sha {
		b, err := os.ReadFile(source.Path)
		if err != nil {
			return nil, err
		}
		v, err := decodeJSON(b)
		doc, ok := v.(map[string]any)
		if err != nil || !ok {
			return nil, fmt.Errorf("source provenance %s: not a JSON object", source.Path)
		}
		transition(doc, source, sha)
		if err := PublishSource(root, slug, doc); err != nil {
			return nil, err
		}
	}
	return BindSource(root, slug)
}

// RestoreSource puts previous (the receipt's bytes before a publication) back, but only when
// published is still intact: bytes published by this operation are rolled back, a concurrent
// edit is never overwritten. A nil published is a no-op.
func RestoreSource(published *SourceRef, previous []byte) error {
	if published == nil || ValidateSource(published) != nil {
		return nil
	}
	return os.WriteFile(published.Path, previous, 0o600)
}

// ValidateSource checks the custody of a bound receipt: the receipt's folder and the three
// above it (`.kogen/local/provenance/<slug>`, `.kogen/local/provenance`, `.kogen/local`,
// `.kogen`) are real directories, the first two are 0700, and the file is a regular 0600 file
// whose bytes still have the recorded SHA-256. A nil reference (legacy) is valid. Otherwise
// it is a `candidate/source_provenance_changed` error (exit 1).
func ValidateSource(ref *SourceRef) error {
	if ref == nil {
		return nil
	}
	parent := filepath.Dir(ref.Path)
	dirs := []string{parent}
	for d, i := parent, 0; i < 3; i++ {
		d = filepath.Dir(d)
		dirs = append(dirs, d)
	}
	for _, d := range dirs {
		if fi, err := os.Lstat(d); err != nil || !fi.IsDir() {
			return refuseBound(ref)
		}
	}
	for _, d := range []string{parent, filepath.Dir(parent)} {
		if fi, err := os.Lstat(d); err != nil || !fi.IsDir() || fi.Mode().Perm() != 0o700 {
			return refuseBound(ref)
		}
	}
	fi, err := os.Lstat(ref.Path)
	if err != nil || !fi.Mode().IsRegular() || fi.Mode().Perm() != 0o600 {
		return refuseBound(ref)
	}
	b, err := os.ReadFile(ref.Path)
	if err != nil || sha256Hex(b) != ref.SHA256 {
		return refuseBound(ref)
	}
	return nil
}

func refuseSource(p string) *sys.Error {
	return sys.Fail("candidate", "source_provenance_changed",
		"source provenance custody missing, changed or unsafe: "+p+"; restore the named exact custody from preserved native receipt history, then run the card; if unavailable, stop", 1)
}

// refuseBound refuses a bound receipt, naming the digest it must still have.
func refuseBound(ref *SourceRef) *sys.Error {
	return refuseSource(ref.Path + " (expected SHA-256 " + ref.SHA256 + ")")
}

// SourceMessage is the line pair the builder and reviewer receive about the receipt, or the
// legacy notice for nil.
func SourceMessage(ref *SourceRef) string {
	if ref == nil {
		return "Source provenance: unavailable (legacy)"
	}
	return "Diagnostic source provenance (not authority): " + ref.Path +
		"\nManifest sha256: " + ref.SHA256 + "; contract: " + ref.ContractSHA256 +
		". Retrieve full originals with read_file. Only the approved Intent authorizes implementation; omissions require ordinary Refine and new exact approval. Mapping is an aid, not proof."
}

// SourceCard is SourceMessage for an approval card: after validating custody, the message
// and the receipt's Source comparison (never the raw request).
func SourceCard(ref *SourceRef) (string, error) {
	if ref == nil {
		return SourceMessage(nil), nil
	}
	if err := ValidateSource(ref); err != nil {
		return "", err
	}
	b, err := os.ReadFile(ref.Path)
	if err != nil {
		return "", err
	}
	doc, err := decodeJSON(b)
	if err != nil {
		return "", fmt.Errorf("source provenance %s: %w", ref.Path, err)
	}
	comparison, ok := doc.(map[string]any)["comparison"].(string)
	if !ok {
		return "", fmt.Errorf("source provenance %s: no comparison", ref.Path)
	}
	return SourceMessage(ref) + "\nSource comparison:\n" + comparison, nil
}

// RefineSource records a successful Refine in the receipt bound by source: it appends the
// correction (with the contract hash it corrected) and replaces the comparison and the
// contract hash with the refined Intent's, publishing a new current receipt (the old one
// stays as its hash-named archive and is named in `previous_receipt`). The bound custody is
// validated before and right before publication. It returns the new current receipt; with no
// receipt (a legacy Intent) it does nothing and returns nil.
func RefineSource(root, slug string, correction SourceRequest, prior string, source *SourceRef) (*SourceRef, error) {
	if err := ValidateSource(source); err != nil {
		return nil, err
	}
	if source == nil {
		return nil, nil
	}
	if !utf8.ValidString(correction.Text) {
		return nil, errors.New("source provenance: the correction is not valid UTF-8")
	}
	b, err := os.ReadFile(SourcePath(root, slug))
	if err != nil {
		return nil, err
	}
	v, err := decodeJSON(b)
	doc, ok := v.(map[string]any)
	if err != nil || !ok {
		return nil, fmt.Errorf("source provenance %s: not a JSON object", SourcePath(root, slug))
	}
	cfg, err := LoadConfig(root)
	if err != nil {
		return nil, err
	}
	corrections, ok := doc["corrections"].([]any)
	if !ok {
		return nil, fmt.Errorf("source provenance %s: corrections is not a list", SourcePath(root, slug))
	}
	entry := map[string]any{
		"text": correction.Text, "source_path": correction.SourcePath, "sha256": correction.SHA256,
		"prior_contract_sha256": prior,
	}
	comparison, err := SourceComparison(root, slug)
	if err != nil {
		return nil, err
	}
	paths, err := Baseline(root, slug, cfg)
	if err != nil {
		return nil, err
	}
	doc["corrections"] = append(slices.Clone(corrections), entry)
	doc["comparison"] = comparison
	transition(doc, source, Hash(root, paths))
	if err := ValidateSource(source); err != nil {
		return nil, err
	}
	now, err := BindSource(root, slug)
	if err != nil {
		return nil, err
	}
	if !now.Equal(source) {
		return nil, refuseSource(SourcePath(root, slug))
	}
	if err := PublishSource(root, slug, doc); err != nil {
		return nil, err
	}
	return BindSource(root, slug)
}

func sha256Hex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// ---- configuration digest ----

// configDigest is the SHA-256 of the Erlang external term format of the configuration as the
// Elixir Kogen holds it (a Kogen.Config struct), which is what `origin.configuration` of a
// receipt records. The Erlang VM writes the keys of a small map in the order of the age of their
// atoms, so the bytes below follow the key order of the current Elixir build; the digest is a
// diagnostic fingerprint that nothing compares. An empty acceptance command or steps folder is
// written as nil, as is an unset one.
func configDigest(cfg *Config) string {
	var e etf
	e.WriteByte(131)
	e.mapHeader(9)
	e.atom("setup")
	e.stringList(cfg.Setup)
	e.atom("__struct__")
	e.atom("Elixir.Kogen.Config")
	e.atom("protect")
	e.stringList(cfg.Protect)
	e.atom("checks")
	if len(cfg.Checks) == 0 {
		e.WriteByte(etfNil)
	} else {
		e.WriteByte(etfList)
		e.u32(len(cfg.Checks))
		for _, c := range cfg.Checks {
			e.WriteByte(etfSmallTuple)
			e.WriteByte(2)
			e.binary(c.Name)
			e.binary(c.Run)
		}
		e.WriteByte(etfNil)
	}
	e.atom("models")
	e.roles(cfg.Models)
	e.atom("fix")
	e.stringList(cfg.Fix)
	var run, steps string
	if cfg.Acceptance != nil {
		run, steps = cfg.Acceptance.Run, cfg.Acceptance.StepsDir
	}
	e.atom("acceptance_run")
	e.optionalBinary(run)
	e.atom("steps_dir")
	e.optionalBinary(steps)
	e.atom("shape_workers")
	e.mapHeader(1 + len(cfg.ShapeWorkers.Roles))
	e.atom("enabled")
	e.atom(strconv.FormatBool(cfg.ShapeWorkers.Enabled))
	for _, name := range sortedKeys(cfg.ShapeWorkers.Roles) {
		e.binary(name)
		e.role(cfg.ShapeWorkers.Roles[name])
	}
	sum := sha256.Sum256(e.Bytes())
	return hex.EncodeToString(sum[:])
}

const (
	etfSmallTuple = 104
	etfNil        = 106
	etfList       = 108
	etfBinary     = 109
	etfMap        = 116
	etfSmallAtom  = 119
)

// etf writes the few Erlang external term shapes a configuration needs.
type etf struct{ bytes.Buffer }

func (e *etf) u32(n int) {
	e.Write([]byte{byte(n >> 24), byte(n >> 16), byte(n >> 8), byte(n)})
}

func (e *etf) mapHeader(arity int) { e.WriteByte(etfMap); e.u32(arity) }

func (e *etf) atom(name string) {
	e.WriteByte(etfSmallAtom)
	e.WriteByte(byte(len(name)))
	e.WriteString(name)
}

func (e *etf) binary(s string) {
	e.WriteByte(etfBinary)
	e.u32(len(s))
	e.WriteString(s)
}

func (e *etf) optionalBinary(s string) {
	if s == "" {
		e.atom("nil")
		return
	}
	e.binary(s)
}

func (e *etf) stringList(list []string) {
	if len(list) == 0 {
		e.WriteByte(etfNil)
		return
	}
	e.WriteByte(etfList)
	e.u32(len(list))
	for _, s := range list {
		e.binary(s)
	}
	e.WriteByte(etfNil)
}

// role is %{effort:, model:} and, when set, provider: in that key order.
func (e *etf) role(r Role) {
	n := 2
	if r.Provider != "" {
		n++
	}
	if r.BaseURL != "" {
		n++
	}
	e.mapHeader(n)
	// Atom keys in term order: base_url (openai-compatible only) sorts before effort.
	if r.BaseURL != "" {
		e.atom("base_url")
		e.binary(r.BaseURL)
	}
	e.atom("effort")
	e.binary(r.Effort)
	e.atom("model")
	e.binary(r.Model)
	if r.Provider != "" {
		e.atom("provider")
		e.binary(r.Provider)
	}
}

func (e *etf) roles(m map[string]Role) {
	e.mapHeader(len(m))
	for _, name := range sortedKeys(m) {
		e.binary(name)
		e.role(m[name])
	}
}

func sortedKeys(m map[string]Role) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
