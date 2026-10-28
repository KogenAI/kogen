package tools

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode"
	"unicode/utf8"

	"kogen-loop/sys"
)

// Output is what a tool returns: text, or typed parts (the pixels of view_image), which the
// provider receives as the function_call_output's list.
type Output struct {
	Text  string
	Parts []any
	// Rule is the rule id of a refused shell call, "" otherwise.
	Rule string
}

// Typed reports whether the output is typed parts.
func (o Output) Typed() bool { return o.Parts != nil }

// Value is the function_call_output's "output": the parts, or the text.
func (o Output) Value() any {
	if o.Parts != nil {
		return o.Parts
	}
	return o.Text
}

// Cut limits text output to 16 KiB (see Cut); typed parts pass unchanged.
func (o Output) Cut() Output {
	if o.Parts != nil {
		return o
	}
	return Output{Text: Cut(o.Text)}
}

// Cut applies this instance's configured budgets (ResultBound, ResultHead) to a text
// output; typed parts pass unchanged. The receiver must be valid (see Validate).
func (t *Tools) Cut(out Output) Output {
	if out.Parts != nil {
		return out
	}
	bound, head := t.budgets()
	return Output{Text: cutText(out.Text, bound, head)}
}

// New validates options and returns a copy of them.
func New(options Tools) (*Tools, error) {
	if err := options.Validate(); err != nil {
		return nil, err
	}
	return &options, nil
}

// Validate checks the nested Documentation options, then ResultBound and ResultHead: negatives are refused, the resolved bound
// must be at least 128, the resolved head below it, and at least 64 bytes must remain
// after the head for the marker and tail.
func (t *Tools) Validate() error {
	if err := t.Documentation.Validate(); err != nil {
		return err
	}
	if t.ResultBound < 0 {
		return fmt.Errorf("tools: ResultBound %d is negative", t.ResultBound)
	}
	if t.ResultHead < 0 {
		return fmt.Errorf("tools: ResultHead %d is negative", t.ResultHead)
	}
	bound, head := t.budgets()
	if bound < minResultBound {
		return fmt.Errorf("tools: ResultBound %d is below the minimum %d", bound, minResultBound)
	}
	if head >= bound {
		return fmt.Errorf("tools: ResultHead %d must be less than ResultBound %d", head, bound)
	}
	if bound-head < minResultTail {
		return fmt.Errorf("tools: ResultBound %d minus ResultHead %d leaves %d bytes remaining, need at least %d for the marker and tail", bound, head, bound-head, minResultTail)
	}
	return nil
}

func (t *Tools) budgets() (bound, head int) {
	bound, head = t.ResultBound, t.ResultHead
	if bound == 0 {
		bound = maxResult
	}
	if head == 0 {
		head = defaultResultHead
	}
	return bound, head
}

// Tools runs the model's tool calls in one repository. A refused or failed call is a tool
// result (text starting `error:` or `refused:`), never a Go error; the only error is an
// interrupt, context stop during timeout custody, or timeout observation failure.
type Tools struct {
	// Root is the repository root; relative paths resolve against it.
	Root string
	// Session runs shell commands (the caller's environment, interrupts) and gives Git its
	// environment. Nil: this process's environment, no interrupts.
	Session *sys.Session
	// ShellTimeout bounds each shell invocation independently. Nonpositive means no limit.
	ShellTimeout time.Duration
	// Repo runs the Git commands of list_files and search_text and the candidate tree of
	// view_image. Nil: Git in Root with the Session's environment (see git.go).
	Repo Git
	// Enabled are the tool names a call may use; any other name is `error: unknown tool`.
	Enabled []string
	// Protected are the root-relative paths write_file refuses (the approved baseline).
	Protected []string
	// Excluded are the paths the candidate tree of view_image leaves out (other
	// uncommitted Intents).
	Excluded []string
	// Probe runs the shaper's probe tool, whose scratch copy and evidence belong to the
	// shaper: command is the validated command argument, files the raw `files` argument
	// (nil when absent). Nil: probe answers that it is unavailable.
	Probe func(command string, files any) (string, error)
	// Documentation is the shaper's documentation tool (user-agent, timeout).
	Documentation Documentation
	// ResultBound is the most UTF-8 bytes of a result the engine delivers (see Cut). Zero:
	// 16384. Library only.
	ResultBound int
	// ResultHead is the bytes kept from the start of a longer result. Zero: 4096.
	ResultHead int
}

const (
	maxResult         = 16_384
	defaultResultHead = 4096
	minResultBound    = 128
	minResultTail     = 64
)

// Run runs one tool call. The arguments are a decoded JSON object (Call.Args).
func (t *Tools) Run(name string, args map[string]any) (Output, error) {
	return t.RunContext(nil, name, args)
}

// RunContext runs a call, forwarding ctx only for positive ShellTimeout custody.
// Overall execution custody remains the caller's responsibility.
func (t *Tools) RunContext(ctx context.Context, name string, args map[string]any) (Output, error) {
	if !slices.Contains(t.Enabled, name) {
		return Output{Text: "error: unknown tool " + name}, nil
	}
	switch name {
	case ViewImageTool:
		return t.viewImage(args), nil
	case ReadFileTool:
		return Output{Text: t.readFile(args)}, nil
	case WriteFileTool:
		return Output{Text: t.writeFile(args)}, nil
	case ListFilesTool:
		return Output{Text: t.listFiles(args)}, nil
	case SearchTextTool:
		return Output{Text: t.searchText(args)}, nil
	case ShellTool:
		text, rule, err := t.shell(ctx, args)
		return Output{Text: text, Rule: rule}, err
	case ProbeTool:
		text, err := t.probe(args)
		return Output{Text: text}, err
	case DocumentationTool:
		return Output{Text: t.Documentation.Lookup(args)}, nil
	}
	return Output{Text: "error: unknown tool " + name}, nil
}

// Call runs a function call of a response.
func (t *Tools) Call(c Call) (Output, error) { return t.CallContext(nil, c) }

// CallContext runs a response call with optional positive-timeout custody cancellation.
func (t *Tools) CallContext(ctx context.Context, c Call) (Output, error) {
	return t.RunContext(ctx, c.Name, c.Args())
}

// ---- arguments and paths ----

// stringArg is the string argument key, or the error text the model gets.
func stringArg(args map[string]any, key string) (string, string) {
	if v, ok := args[key].(string); ok {
		return v, ""
	}
	return "", "error: argument " + key + " must be a string"
}

func optionalPath(args map[string]any) string {
	if p, ok := args["path"].(string); ok {
		return p
	}
	return "."
}

// expand is the absolute, cleaned form of path against root; a leading ~ is the home folder.
func expand(path, root string) string {
	if path == "~" || strings.HasPrefix(path, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			path = home + path[1:]
		}
	}
	if !filepath.IsAbs(path) {
		path = filepath.Join(root, path)
	}
	return filepath.Clean(path)
}

// relativeTo is abs relative to root, "." for root itself, and abs unchanged when it is
// not inside root. Neither path is resolved: there is no containment, only protection.
func relativeTo(abs, root string) string {
	root = filepath.Clean(root)
	switch {
	case abs == root:
		return "."
	case root == "/" && strings.HasPrefix(abs, "/"):
		return abs[1:]
	case strings.HasPrefix(abs, root+"/"):
		return abs[len(root)+1:]
	}
	return abs
}

// resolve is the absolute and the root-relative form of a path argument.
func (t *Tools) resolve(path string) (abs, rel string) {
	abs = expand(path, t.Root)
	return abs, relativeTo(abs, t.Root)
}

// errno names, as the Erlang file functions report them.
var errnoNames = map[syscall.Errno]string{
	syscall.EPERM: "eperm", syscall.ENOENT: "enoent", syscall.EIO: "eio", syscall.EBADF: "ebadf",
	syscall.ENOMEM: "enomem", syscall.EACCES: "eacces", syscall.EBUSY: "ebusy", syscall.EEXIST: "eexist",
	syscall.EXDEV: "exdev", syscall.ENOTDIR: "enotdir", syscall.EISDIR: "eisdir", syscall.EINVAL: "einval",
	syscall.ENFILE: "enfile", syscall.EMFILE: "emfile", syscall.EFBIG: "efbig", syscall.ENOSPC: "enospc",
	syscall.ESPIPE: "espipe", syscall.EROFS: "erofs", syscall.EMLINK: "emlink", syscall.ENAMETOOLONG: "enametoolong",
	syscall.ENOTEMPTY: "enotempty", syscall.ELOOP: "eloop", syscall.EDQUOT: "edquot", syscall.ETXTBSY: "etxtbsy",
	syscall.ESTALE: "estale", syscall.EAGAIN: "eagain", syscall.EINTR: "eintr", syscall.ENXIO: "enxio",
	syscall.ENODEV: "enodev", syscall.ENOTSUP: "enotsup", syscall.EOVERFLOW: "eoverflow",
}

// reason is the Erlang POSIX atom of a file error ("enoent"), or the error text.
func reason(err error) string {
	var errno syscall.Errno
	if errors.As(err, &errno) {
		if n, ok := errnoNames[errno]; ok {
			return n
		}
	}
	var pe *fs.PathError
	if errors.As(err, &pe) {
		return pe.Err.Error()
	}
	return err.Error()
}

func isErrno(err error, want syscall.Errno) bool {
	var errno syscall.Errno
	return errors.As(err, &errno) && errno == want
}

// ---- the tools ----

func (t *Tools) readFile(args map[string]any) string {
	path, msg := stringArg(args, "path")
	if msg != "" {
		return msg
	}
	abs, _ := t.resolve(path)
	data, err := readFile(abs)
	switch {
	case err == nil:
		return numbered(string(data), args["start_line"], args["end_line"])
	case isErrno(err, syscall.ENOENT):
		return "error: " + path + " does not exist"
	case isErrno(err, syscall.EISDIR):
		return "error: " + path + " is a folder; use list_files"
	}
	return "error: " + path + ": " + reason(err)
}

// numbered is the lines from..to of text (1-based, inclusive) as `<n>\t<line>` joined by
// newlines. A final newline ends the last line instead of starting another; from defaults
// to 1 unless it is a positive integer, to to the last line unless it is an integer not
// below from.
func numbered(text string, fromArg, toArg any) string {
	lines := strings.Split(text, "\n")
	if lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	from := int64(1)
	if n, ok := integerValue(fromArg); ok && n > 0 {
		from = n
	}
	to := int64(len(lines))
	if n, ok := integerValue(toArg); ok && n >= from {
		to = n
	}
	var b strings.Builder
	for i, l := range lines {
		n := int64(i + 1)
		if n < from || n > to {
			continue
		}
		if b.Len() > 0 {
			b.WriteByte('\n')
		}
		b.WriteString(strconv.FormatInt(n, 10) + "\t" + l)
	}
	return b.String()
}

// integerValue is v when it is a JSON integer (not a float), clamped to int64.
func integerValue(v any) (int64, bool) {
	switch n := v.(type) {
	case int64:
		return n, true
	case int:
		return int64(n), true
	case json.Number: // beyond int64, or a float
		s := n.String()
		if strings.ContainsAny(s, ".eE") {
			return 0, false
		}
		if strings.HasPrefix(s, "-") {
			return -1 << 63, true
		}
		return 1<<63 - 1, true
	}
	return 0, false
}

func (t *Tools) writeFile(args map[string]any) string {
	path, msg := stringArg(args, "path")
	if msg != "" {
		return msg
	}
	content, msg := stringArg(args, "content")
	if msg != "" {
		return msg
	}
	abs, rel := t.resolve(path)
	if slices.Contains(t.Protected, rel) {
		return "refused: " + rel + " is part of the approved acceptance baseline"
	}
	if err := mkdirAll(filepath.Dir(abs)); err != nil {
		return "error: " + path + ": " + reason(err)
	}
	if err := writeFile(abs, content); err != nil {
		return "error: " + path + ": " + reason(err)
	}
	return "ok"
}

// errBadArg is what a path with a NUL byte is: not a file name at all.
var errBadArg = errors.New("badarg")

func readFile(abs string) ([]byte, error) {
	if strings.ContainsRune(abs, 0) {
		return nil, errBadArg
	}
	return os.ReadFile(abs)
}

func writeFile(abs, content string) error {
	if strings.ContainsRune(abs, 0) {
		return errBadArg
	}
	return os.WriteFile(abs, []byte(content), 0o666)
}

// mkdirAll creates dir and its missing parents. What exists there as anything but a folder
// (or a link to one) is ENOTDIR.
func mkdirAll(dir string) error {
	if strings.ContainsRune(dir, 0) {
		return errBadArg
	}
	parent := filepath.Dir(dir)
	if dir == "/" || parent == dir {
		return nil
	}
	if err := mkdirAll(parent); err != nil {
		return err
	}
	err := os.Mkdir(dir, 0o777)
	if isErrno(err, syscall.EEXIST) {
		if isDir(dir) {
			return nil
		}
		return syscall.ENOTDIR
	}
	return err
}

func isDir(path string) bool {
	st, err := os.Stat(path)
	return err == nil && st.IsDir()
}

func (t *Tools) repo() Git {
	if t.Repo != nil {
		return t.Repo
	}
	return newRunner(t.Root, t.session().Env)
}

// session is the Session, or one for this process's environment.
func (t *Tools) session() *sys.Session {
	if t.Session != nil {
		return t.Session
	}
	return sys.NewWith(os.Environ(), t.Root)
}

// pathspec is the Git path restriction for a path argument: none for the root itself.
func (t *Tools) pathspec(args map[string]any) []string {
	_, rel := t.resolve(optionalPath(args))
	if rel == "" || rel == "." {
		return nil
	}
	return []string{cString(rel)}
}

// cString is s up to its first NUL byte: what a program receives of an argument.
func cString(s string) string {
	if i := strings.IndexByte(s, 0); i >= 0 {
		return s[:i]
	}
	return s
}

// gitFailure is the text of a failed Git command: its output, stdout then stderr.
func gitFailure(res GitResult) string {
	return "error: " + strings.TrimSpace(res.Stdout+res.Stderr)
}

func (t *Tools) listFiles(args map[string]any) string {
	argv := append([]string{"ls-files", "--cached", "--others", "--exclude-standard", "--deduplicate", "--"}, t.pathspec(args)...)
	res, err := t.repo().Run(argv...)
	switch {
	case err != nil:
		return "error: " + err.Error()
	case res.Status != 0:
		return gitFailure(res)
	case res.Stdout == "":
		return "(no files)"
	}
	return trimTrailing(res.Stdout)
}

func (t *Tools) searchText(args map[string]any) string {
	pattern, msg := stringArg(args, "pattern")
	if msg != "" {
		return msg
	}
	argv := append([]string{"grep", "-n", "-I", "-E", "--untracked", "-e", cString(pattern), "--"}, t.pathspec(args)...)
	res, err := t.repo().Run(argv...)
	switch {
	case err != nil:
		return "error: " + err.Error()
	case res.Status == 0:
		return trimTrailing(res.Stdout)
	case res.Status == 1:
		return "(no matches)"
	}
	return gitFailure(res)
}

// shell runs /bin/sh -c in the repository root with stdin closed and ShellTimeout.
// Only an expired timeout prefixes the ordinary exit status and combined output.
// A command that would stop processes this run did not start is refused with
// sys.RefusalText as ordinary tool text. KillGroupOnExit stays off: background servers
// outlive a call, and round and engine cleanup end them with the round.
func (t *Tools) shell(ctx context.Context, args map[string]any) (string, string, error) {
	command, msg := stringArg(args, "command")
	if msg != "" {
		return msg, "", nil
	}
	opts := sys.Options{Timeout: t.ShellTimeout, RefuseForeignKill: true}
	if t.ShellTimeout > 0 {
		opts.Context = ctx
	}
	res, err := t.session().Run(command, t.Root, opts)
	if err != nil {
		return "", "", err
	}
	if res.Rule != "" {
		return res.Output, res.Rule, nil
	}
	text := "exit status: " + strconv.Itoa(res.Status) + "\n" + res.Output
	if res.TimedOut {
		text = "timed out after " + t.ShellTimeout.String() + "\n" + text
	}
	return text, "", nil
}

func (t *Tools) probe(args map[string]any) (string, error) {
	command, msg := stringArg(args, "command")
	if msg != "" {
		return msg, nil
	}
	if t.Probe == nil {
		return "error: probe is not available", nil
	}
	return t.Probe(command, args["files"])
}

// ---- cut ----

// Cut bounds model-facing text to 16384 UTF-8 bytes including the omission marker (LOOP-8).
// Fitting text is unchanged. Longer text keeps its first 4096 bytes and a suffix, each
// backing off an incomplete UTF-8 character, around a marker that counts the bytes actually
// absent; reserving the marker's width for the whole text's digit count is conservative and
// may leave a few unused bytes. Cutting a cut text changes nothing. Typed image results
// (Output.Cut) pass unchanged and the private originals a result was read from are never
// transformed: the bound applies once, where a result is delivered.
func Cut(text string) string { return cutText(text, maxResult, defaultResultHead) }

func cutText(text string, bound, headSize int) string {
	if len(text) <= bound {
		return text
	}
	marker := func(n int) string { return fmt.Sprintf("\n[... %d bytes omitted ...]\n", n) }
	head := validPrefix(text[:headSize])
	tailSize := bound - headSize - len(marker(len(text)))
	tail := validSuffix(text[len(text)-tailSize:])
	return head + marker(len(text)-len(head)-len(tail)) + tail
}

func validPrefix(s string) string {
	for !utf8.ValidString(s) {
		s = s[:len(s)-1]
	}
	return s
}

func validSuffix(s string) string {
	for !utf8.ValidString(s) {
		s = s[1:]
	}
	return s
}

// trimTrailing removes trailing Unicode white space.
func trimTrailing(s string) string { return strings.TrimRightFunc(s, unicode.IsSpace) }
