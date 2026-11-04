package tools

import (
	"context"
	crand "crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"math"
	"math/rand/v2"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode"
	"unicode/utf8"

	"kogen-loop/api"
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

// Classified is an Output with the category of a failed call, for the session's event log. The
// category comes from the call and the tool's own failure path, never from the text; the
// model sees only the Output.
type Classified struct {
	Text  string
	Parts []any
	Rule  string
	// ErrorKind is the api.ToolError* kind of a well-formed call whose tool failed, "" otherwise.
	ErrorKind string
	// MalformedClass is the api.Malformed* class of a call the tool rejected as wrong, "" otherwise.
	MalformedClass string
	// ShellWait is the bounded wait of a shell call that reached it, nil for every other call.
	ShellWait *ShellWait
}

// ShellWait is the bounded wait of one shell call.
type ShellWait struct {
	Spawned     time.Time // zero: no process had started when the wait ended
	WaitStarted time.Time
	WaitEnded   time.Time
	EndedBy     string // api.ShellWaitExit, api.ShellWaitBound or api.ShellWaitHandleYielded
}

// Output is what the model receives of the call.
func (c Classified) Output() Output { return Output{Text: c.Text, Parts: c.Parts, Rule: c.Rule} }

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

// Tools runs the model's tool calls in one repository. A refused or failed call is a tool
// result (text starting `error:` or `refused:`), never a Go error; the only errors are an
// interrupt and a done context that stopped a shell.
type Tools struct {
	// Root is the repository root; relative paths resolve against it.
	Root string
	// Session runs shell commands (the caller's environment, interrupts) and gives Git its
	// environment. Nil: this process's environment, no interrupts.
	Session *sys.Session
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
	// ShellAfter is a test seam. Production leaves it nil and the shell wait uses a real
	// timer. When set, a shell call that reaches its wait passes ShellAfter the wait it
	// would otherwise take, starts no timer and treats a value received from the returned
	// channel as that wait elapsing. It cannot change the wait itself.
	ShellAfter func(wait time.Duration) <-chan time.Time
	shells     *shellRegistry
}

const (
	maxResult         = 16_384
	defaultResultHead = 4096
)

// Run runs one tool call. The arguments are a decoded JSON object (Call.Args).
func (t *Tools) Run(name string, args map[string]any) (Output, error) {
	return t.RunContext(nil, name, args)
}

// RunContext runs a call. ctx (nil: never done) is forwarded to shell commands: a shell
// that has not started does not start once ctx is done, and one that is starting or running
// has its process group terminated and joined before the call returns ctx.Err(). Processes
// a finished shell left behind are not touched here; the round's custody ends them.
func (t *Tools) RunContext(ctx context.Context, name string, args map[string]any) (Output, error) {
	c, err := t.RunClassified(ctx, name, args)
	return c.Output(), err
}

// RunClassified is RunContext with the category of a failed call.
func (t *Tools) RunClassified(ctx context.Context, name string, args map[string]any) (Classified, error) {
	if !slices.Contains(t.Enabled, name) {
		return unknownTool(name), nil
	}
	switch name {
	case ViewImageTool:
		return t.viewImage(args), nil
	case ReadFileTool:
		return t.readFile(args), nil
	case WriteFileTool:
		return t.writeFile(args), nil
	case ListFilesTool:
		return t.listFiles(args), nil
	case SearchTextTool:
		return t.searchText(args), nil
	case ShellTool:
		return t.shell(ctx, args)
	case ProbeTool:
		text, err := t.probe(args)
		return Classified{Text: text}, err
	case DocumentationTool:
		return Classified{Text: t.Documentation.Lookup(args)}, nil
	}
	return unknownTool(name), nil
}

func unknownTool(name string) Classified {
	return Classified{Text: "error: unknown tool " + name, MalformedClass: api.MalformedUnknownTool}
}

// Call runs a function call of a response.
func (t *Tools) Call(c Call) (Output, error) { return t.CallContext(nil, c) }

// CallContext runs a response call like RunContext.
func (t *Tools) CallContext(ctx context.Context, c Call) (Output, error) {
	return t.RunContext(ctx, c.Name, c.Args())
}

// CallClassified runs a response call like RunClassified.
func (t *Tools) CallClassified(ctx context.Context, c Call) (Classified, error) {
	return t.RunClassified(ctx, c.Name, c.Args())
}

// ---- arguments and paths ----

// stringArg is the string argument key, or the error text the model gets.
func stringArg(args map[string]any, key string) (string, string) {
	if v, ok := args[key].(string); ok {
		return v, ""
	}
	return "", "error: argument " + key + " must be a string"
}

// badArg is the refused call of a string argument that is absent or not a string.
func badArg(args map[string]any, key, msg string) Classified {
	class := api.MalformedWrongArgumentType
	if _, ok := args[key]; !ok {
		class = api.MalformedMissingArgument
	}
	return Classified{Text: msg, MalformedClass: class}
}

func failed(kind, text string) Classified { return Classified{Text: text, ErrorKind: kind} }

func optionalPath(args map[string]any) string {
	if p, ok := args["path"].(string); ok {
		return p
	}
	return "."
}

// expand is the absolute, cleaned form of path against root; a leading ~ is the home folder.
// Only write_file uses it: the reading tools are confined to the root (see contain).
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

func (t *Tools) readFile(args map[string]any) Classified {
	path, msg := stringArg(args, "path")
	if msg != "" {
		return badArg(args, "path", msg)
	}
	start, hasStart, bad := lineArg(args, "start_line")
	if bad != nil {
		return *bad
	}
	end, hasEnd, bad := lineArg(args, "end_line")
	if bad != nil {
		return *bad
	}
	from := max(start, 1)
	if hasEnd && end < from {
		return Classified{
			Text:           "error: end_line " + strconv.FormatInt(end, 10) + " is before start_line " + strconv.FormatInt(from, 10),
			MalformedClass: api.MalformedConflictingArguments,
		}
	}
	data, err := t.readContained(path)
	switch {
	case err == nil:
		text := string(data)
		if lines := lineCount(text); hasStart && from > lines {
			return Classified{Text: "(start_line " + strconv.FormatInt(from, 10) + " is past the end of " + path +
				"; line count: " + strconv.FormatInt(lines, 10) + ")"}
		}
		return Classified{Text: numbered(text, args["start_line"], args["end_line"])}
	case refusal(path, err) != "":
		return failed(api.ToolErrorOutsideRoot, refusal(path, err))
	case isErrno(err, syscall.ENOENT):
		return failed(api.ToolErrorNotFound, "error: "+path+" does not exist")
	case isErrno(err, syscall.EISDIR):
		return failed(api.ToolErrorIsFolder, "error: "+path+" is a folder; use list_files")
	}
	return failed(api.ToolErrorFile, "error: "+path+": "+reason(err))
}

// lineArg is the optional line-number argument key: its value (clamped to int64) and
// whether it is present, or the refused call when it is not a JSON integer.
func lineArg(args map[string]any, key string) (int64, bool, *Classified) {
	v, ok := args[key]
	if !ok {
		return 0, false, nil
	}
	if n, ok := integerValue(v); ok {
		return n, true, nil
	}
	text := "error: argument " + key + " must be an integer"
	if n, ok := v.(json.Number); ok {
		if f, err := strconv.ParseFloat(n.String(), 64); err != nil || math.IsInf(f, 0) {
			text = "error: argument " + key + " is a number too large to represent"
		}
	}
	return 0, false, &Classified{Text: text, MalformedClass: api.MalformedWrongArgumentType}
}

// lineCount is the number of lines numbered shows: a final newline ends the last line.
func lineCount(text string) int64 {
	n := int64(strings.Count(text, "\n"))
	if text != "" && !strings.HasSuffix(text, "\n") {
		n++
	}
	return n
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

func (t *Tools) writeFile(args map[string]any) Classified {
	path, msg := stringArg(args, "path")
	if msg != "" {
		return badArg(args, "path", msg)
	}
	content, msg := stringArg(args, "content")
	if msg != "" {
		return badArg(args, "content", msg)
	}
	abs, rel := t.resolve(path)
	if slices.Contains(t.Protected, rel) {
		return failed(api.ToolErrorProtected, "refused: "+rel+" is part of the approved acceptance baseline")
	}
	if strings.ContainsRune(abs, 0) {
		return failed(api.ToolErrorFile, "error: "+path+": "+reason(errBadArg))
	}
	if len(t.Protected) > 0 {
		root, err := resolvedWriteDestination(t.Root)
		if err != nil {
			return failed(api.ToolErrorFile, "error: "+path+": "+reason(err))
		}
		target, err := resolvedWriteDestination(abs)
		if err != nil {
			return failed(api.ToolErrorFile, "error: "+path+": "+reason(err))
		}
		rel = relativeTo(target, root)
		if slices.Contains(t.Protected, rel) {
			return failed(api.ToolErrorProtected, "refused: "+rel+" is part of the approved acceptance baseline")
		}
	}
	if err := mkdirAll(filepath.Dir(abs)); err != nil {
		return failed(api.ToolErrorFile, "error: "+path+": "+reason(err))
	}
	if err := writeFile(abs, content); err != nil {
		return failed(api.ToolErrorFile, "error: "+path+": "+reason(err))
	}
	return Classified{Text: "ok"}
}

// resolvedWriteDestination follows links even when the eventual destination is missing.
// It does not create directories or open the destination for writing.
func resolvedWriteDestination(path string) (string, error) {
	path, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	pending := splitPath(path)
	target := string(os.PathSeparator)
	links := 0
	for len(pending) > 0 {
		part := pending[0]
		pending = pending[1:]
		if part == ".." {
			target = filepath.Dir(target)
			continue
		}
		candidate := filepath.Join(target, part)
		st, err := os.Lstat(candidate)
		if isErrno(err, syscall.ENOENT) {
			target = candidate
			continue
		}
		if err != nil {
			return "", err
		}
		if st.Mode()&os.ModeSymlink == 0 {
			target = candidate
			continue
		}
		links++
		if links > 40 {
			return "", syscall.ELOOP
		}
		link, err := os.Readlink(candidate)
		if err != nil {
			return "", err
		}
		if filepath.IsAbs(link) {
			target = string(os.PathSeparator)
		}
		pending = append(splitPath(link), pending...)
	}
	return target, nil
}

// errBadArg is what a path with a NUL byte is: not a file name at all.
var errBadArg = errors.New("badarg")

func writeFile(abs, content string) error {
	if strings.ContainsRune(abs, 0) {
		return errBadArg
	}
	target, mode, err := replacementTarget(abs)
	if err != nil {
		return err
	}
	tmp, err := createSibling(target, mode)
	if err != nil {
		return err
	}
	_, err = tmp.WriteString(content)
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(tmp.Name(), target)
	}
	if err != nil {
		os.Remove(tmp.Name())
	}
	return err
}

// replacementTarget is the file a write replaces and the permission bits its replacement
// takes: an existing symlink is followed (the link itself stays), an existing regular file
// keeps its bits and must be writable, a missing file is created with 0666 subject to the
// umask (mode -1). Anything else that exists is refused without a change.
func replacementTarget(abs string) (string, int, error) {
	target := abs
	for hops := 0; ; hops++ {
		// Resolve parent components before cleaning: a symlink followed by .. is
		// relative to the symlink's destination, not its containing directory.
		if i := strings.LastIndexByte(target, byte(os.PathSeparator)); i >= 0 {
			parent := target[:i]
			if parent == "" {
				parent = string(os.PathSeparator)
			}
			resolved, err := filepath.EvalSymlinks(parent)
			if err != nil {
				return "", 0, err
			}
			target = filepath.Join(resolved, target[i+1:])
		}
		st, err := os.Lstat(target)
		if isErrno(err, syscall.ENOENT) {
			return target, -1, nil
		}
		if err != nil {
			return "", 0, err
		}
		switch {
		case st.Mode()&os.ModeSymlink != 0:
			if hops >= 40 {
				return "", 0, syscall.ELOOP
			}
			link, err := os.Readlink(target)
			if err != nil {
				return "", 0, err
			}
			if !filepath.IsAbs(link) {
				link = filepath.Dir(target) + string(os.PathSeparator) + link
			}
			target = link
		case st.IsDir():
			return "", 0, syscall.EISDIR
		case !st.Mode().IsRegular():
			return "", 0, syscall.EINVAL
		default:
			// A read-only file stays unwritten although its folder is writable.
			f, err := os.OpenFile(target, os.O_WRONLY, 0)
			if err != nil {
				return "", 0, err
			}
			f.Close()
			return target, int(st.Mode().Perm()), nil
		}
	}
}

// createSibling creates an exclusive temporary file next to target. A mode below zero (the
// umask decides) is left as created; any other mode is set exactly.
func createSibling(target string, mode int) (*os.File, error) {
	dir := filepath.Dir(target)
	for try := 0; ; try++ {
		name := filepath.Join(dir, ".kogen-write-"+strconv.FormatUint(rand.Uint64(), 36))
		f, err := os.OpenFile(name, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o666)
		if isErrno(err, syscall.EEXIST) && try < 100 {
			continue
		}
		if err != nil {
			return nil, err
		}
		if mode >= 0 {
			if err := f.Chmod(os.FileMode(mode)); err != nil {
				f.Close()
				os.Remove(name)
				return nil, err
			}
		}
		return f, nil
	}
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

// pathspec is the Git path restriction for a path argument: none for the root itself. A path
// that leaves the root, by name, home, `..` or a symlink, is refused with the error text.
func (t *Tools) pathspec(args map[string]any) ([]string, Classified) {
	path := cString(optionalPath(args)) // Git receives an argument only up to its first NUL
	// Git top-anchored pathspecs are relative to the Git worktree, which can be
	// an ancestor of Tools.Root. They must not bypass root containment.
	if strings.HasPrefix(path, ":/") || strings.HasPrefix(path, ":(") && strings.Contains(strings.SplitN(path, ")", 2)[0], "top") {
		return nil, failed(api.ToolErrorOutsideRoot, refusal(path, errOutside))
	}
	physical, err := t.contain(path, true)
	if err != nil {
		if text := refusal(path, err); text != "" {
			return nil, failed(api.ToolErrorOutsideRoot, text)
		}
		return nil, failed(api.ToolErrorFile, "error: "+path+": "+reason(err))
	}
	// Git sees the path as written when that stays inside; the resolved one otherwise.
	_, rel := t.resolve(path)
	if root, err := t.canonicalRoot(); err == nil && filepath.IsAbs(rel) {
		rel = relativeTo(rel, root)
	}
	if filepath.IsAbs(rel) || rel == ".." || strings.HasPrefix(rel, "../") {
		rel = physical
	}
	if rel == "" || rel == "." {
		return nil, Classified{}
	}
	return []string{cString(rel)}, Classified{}
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

// renderPath is a path as the model sees it: verbatim when it is valid UTF-8, printable and
// does not start with a double quote, otherwise strconv.Quote of it.
func renderPath(p string) string {
	if utf8.ValidString(p) && !strings.HasPrefix(p, `"`) && !strings.ContainsFunc(p, func(r rune) bool { return !strconv.IsPrint(r) }) {
		return p
	}
	return strconv.Quote(p)
}

// renderMatches turns the records of git grep -z -n, <path> NUL <number> NUL <text> LF, into
// <rendered path>:<number>:<text> lines, keeping only the records whose text matches re. A
// record that does not have that shape ends the parse and is kept as it came.
func renderMatches(out string, re *regexp.Regexp) string {
	var b strings.Builder
	for out != "" {
		path, rest, ok := strings.Cut(out, "\x00")
		if !ok {
			b.WriteString(out)
			break
		}
		num, rest, ok := strings.Cut(rest, "\x00")
		if !ok {
			b.WriteString(out)
			break
		}
		text, rest, hasLF := strings.Cut(rest, "\n")
		out = rest
		if !re.MatchString(text) {
			continue
		}
		b.WriteString(renderPath(path) + ":" + num + ":" + text)
		if hasLF {
			b.WriteByte('\n')
		}
	}
	return b.String()
}

func (t *Tools) listFiles(args map[string]any) Classified {
	spec, refused := t.pathspec(args)
	if refused.Text != "" {
		return refused
	}
	argv := append([]string{"ls-files", "-z", "--cached", "--others", "--exclude-standard", "--deduplicate", "--"}, spec...)
	res, err := t.repo().Run(argv...)
	switch {
	case err != nil:
		return failed(api.ToolErrorGit, "error: "+err.Error())
	case res.Status != 0:
		return failed(api.ToolErrorGit, gitFailure(res))
	case res.Stdout == "":
		return Classified{Text: "(no files)"}
	}
	names := strings.Split(strings.TrimSuffix(res.Stdout, "\x00"), "\x00")
	for i, name := range names {
		names[i] = renderPath(name)
	}
	return Classified{Text: strings.Join(names, "\n")}
}

func (t *Tools) searchText(args map[string]any) Classified {
	pattern, msg := stringArg(args, "pattern")
	if msg != "" {
		return badArg(args, "pattern", msg)
	}
	if strings.ContainsRune(pattern, 0) {
		return failed(api.ToolErrorGit, "error: pattern contains a NUL character")
	}
	spec, refused := t.pathspec(args)
	if refused.Text != "" {
		return refused
	}
	re, err := regexp.Compile(pattern)
	if err != nil {
		return failed(api.ToolErrorGit, "error: invalid pattern: "+strings.TrimPrefix(err.Error(), "error parsing regexp: "))
	}
	argv := append([]string{"grep", "-z", "-n", "-I", "-E", "--untracked", "-e", "", "--"}, spec...)
	res, err := t.repo().Run(argv...)
	switch {
	case err != nil:
		return failed(api.ToolErrorGit, "error: "+err.Error())
	case res.Status == 0:
		if text := trimTrailing(renderMatches(res.Stdout, re)); text != "" {
			return Classified{Text: text}
		}
		return Classified{Text: "(no matches)"}
	case res.Status == 1:
		return Classified{Text: "(no matches)"}
	}
	return failed(api.ToolErrorGit, gitFailure(res))
}

type shellJob struct {
	cmd    *sys.CapturedCommand
	cancel context.CancelFunc
}
type shellRegistry struct {
	mu   sync.Mutex
	jobs map[string]*shellJob
}

var shellRegistryInit sync.Mutex

func (t *Tools) registry() *shellRegistry {
	shellRegistryInit.Lock()
	defer shellRegistryInit.Unlock()
	if t.shells == nil {
		t.shells = &shellRegistry{jobs: map[string]*shellJob{}}
	}
	return t.shells
}

// EndShellRound cancels and joins outstanding commands and expires their handles.
func (t *Tools) EndShellRound() {
	r := t.registry()
	r.mu.Lock()
	jobs := r.jobs
	r.jobs = map[string]*shellJob{}
	r.mu.Unlock()
	for _, j := range jobs {
		j.cancel()
	}
	for _, j := range jobs {
		j.cmd.Stop(j.cancel)
	}
}

// SignalShellHandle cancels a yielded command without waiting or expiring its handle.
func (t *Tools) SignalShellHandle(id string) {
	r := t.registry()
	r.mu.Lock()
	j := r.jobs[id]
	if j != nil {
		j.cancel()
	}
	r.mu.Unlock()
}

// CancelShellHandle stops a yielded command whose staged result was discarded.
func (t *Tools) CancelShellHandle(id string) {
	r := t.registry()
	r.mu.Lock()
	j := r.jobs[id]
	delete(r.jobs, id)
	r.mu.Unlock()
	if j != nil {
		j.cmd.Stop(j.cancel)
	}
}
func (t *Tools) shell(ctx context.Context, args map[string]any) (Classified, error) {
	command, hasCommand := args["command"]
	cmd, commandIsString := command.(string)
	handle, _ := args["handle"].(string)
	usableCommand := commandIsString && strings.TrimSpace(cmd) != ""
	hasHandle := strings.TrimSpace(handle) != ""
	if !hasHandle && hasCommand && !commandIsString {
		return Classified{Text: "error: argument command must be a string", MalformedClass: api.MalformedWrongArgumentType}, nil
	}
	if usableCommand == hasHandle {
		class := api.MalformedMissingArgument
		if usableCommand {
			class = api.MalformedConflictingArguments
		}
		return Classified{Text: "error: supply exactly one of command or handle", MalformedClass: class}, nil
	}
	if ctx != nil && ctx.Err() != nil {
		return Classified{}, ctx.Err()
	}
	r := t.registry()
	var j *shellJob
	var id string
	if hasHandle {
		id = handle
		r.mu.Lock()
		j = r.jobs[id]
		r.mu.Unlock()
		if j == nil {
			return failed(api.ToolErrorUnknownShellHandle, "error: unknown shell handle"), nil
		}
	} else {
		var token [16]byte
		if _, err := crand.Read(token[:]); err != nil {
			return Classified{}, err
		}
		id = hex.EncodeToString(token[:])
		jobctx, cancel := context.WithCancel(context.Background())
		r.mu.Lock()
		j = &shellJob{cmd: t.session().StartCaptured(jobctx, cmd, t.Root), cancel: cancel}
		r.jobs[id] = j
		r.mu.Unlock()
	}
	wait := 45 * time.Second
	if hasHandle {
		wait = 30 * time.Second
	}
	var elapsed <-chan time.Time
	waitStarted := time.Now()
	if t.ShellAfter != nil {
		elapsed = t.ShellAfter(wait)
	} else {
		timer := time.NewTimer(wait)
		defer timer.Stop()
		elapsed = timer.C
	}
	var done <-chan struct{}
	if ctx != nil {
		done = ctx.Done()
	}
	select {
	case <-j.cmd.Done():
	case <-elapsed:
	case <-done:
		j.cancel()
		<-j.cmd.Done()
		if t.Session != nil && t.Session.Err() != nil {
			return Classified{}, t.Session.Err()
		}
		return Classified{}, ctx.Err()
	}
	if ctx != nil && ctx.Err() != nil {
		j.cancel()
		<-j.cmd.Done()
		if t.Session != nil && t.Session.Err() != nil {
			return Classified{}, t.Session.Err()
		}
		return Classified{}, ctx.Err()
	}
	waitEnded := time.Now()
	spawned := j.cmd.Started()
	if spawned.After(waitEnded) {
		spawned = time.Time{}
	}
	res, completed, err := j.cmd.Snapshot()
	if err != nil {
		return Classified{}, err
	}
	endedBy := api.ShellWaitExit
	if !completed {
		endedBy = api.ShellWaitHandleYielded
		if hasHandle {
			endedBy = api.ShellWaitBound
		}
	}
	record := &ShellWait{Spawned: spawned, WaitStarted: waitStarted, WaitEnded: waitEnded, EndedBy: endedBy}
	if !hasHandle && completed {
		r.mu.Lock()
		delete(r.jobs, id)
		r.mu.Unlock()
		j.cancel()
		if res.Rule != "" {
			return Classified{Text: res.Output, Rule: res.Rule, ErrorKind: api.ToolErrorForeignKill, ShellWait: record}, nil
		}
		return Classified{Text: "exit status: " + strconv.Itoa(res.Status) + "\n" + res.Output, ShellWait: record}, nil
	}
	output := res.Output
	if !utf8.ValidString(output) {
		output = string([]rune(output))
	}
	envelope := map[string]any{"status": "running", "handle": id, "output": output}
	if completed {
		envelope["status"] = "completed"
		envelope["exit_status"] = res.Status
	}
	raw, _ := json.Marshal(envelope)
	if len(raw) > maxResult {
		// JSON escaping expands some bytes. Cut output, never the envelope.
		lo, hi := 100, min(len(output), maxResult)
		for lo < hi {
			mid := (lo + hi + 1) / 2
			envelope["output"] = cutText(output, mid, mid/4)
			b, _ := json.Marshal(envelope)
			if len(b) <= maxResult {
				lo = mid
			} else {
				hi = mid - 1
			}
		}
		envelope["output"] = cutText(output, lo, lo/4)
		raw, _ = json.Marshal(envelope)
	}
	return Classified{Text: string(raw), ShellWait: record}, nil
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
// Invalid UTF-8 bytes are replaced before bounding. Valid fitting text is unchanged. Longer text keeps complete lines within a 4096-byte head budget and a suffix budget,
// falling back to UTF-8-safe byte cuts when no line boundary fits, around a marker that counts the bytes actually
// absent (and, when both cut points fall on line boundaries, the lines and for numbered read_file text their numbers); reserving the marker's width for the whole text's digit count is conservative and
// may leave a few unused bytes. Cutting a cut text changes nothing. Typed image results
// (Output.Cut) pass unchanged and the private originals a result was read from are never
// transformed: the bound applies once, where a result is delivered.
func Cut(text string) string {
	if !utf8.ValidString(text) {
		text = string([]rune(text))
	}
	return cutText(text, maxResult, defaultResultHead)
}

func cutText(text string, bound, headSize int) string {
	if len(text) <= bound {
		return text
	}
	head := validPrefix(text[:headSize])
	if i := strings.LastIndexByte(head, '\n'); i >= 0 {
		head = head[:i+1]
	}
	if strings.HasSuffix(head, "\n") {
		if cut, ok := cutLines(text, head, bound, headSize); ok {
			return cut
		}
	}
	marker := func(n int) string { return fmt.Sprintf("\n[... %d bytes omitted ...]\n", n) }
	tailSize := bound - headSize - len(marker(len(text)))
	tail := validSuffix(text[len(text)-tailSize:])
	if i := strings.IndexByte(tail, '\n'); i >= 0 {
		tail = tail[i+1:]
	}
	return head + marker(len(text)-len(head)-len(tail)) + tail
}

// cutLines is the line form of cutText for a head that ends at a line boundary: the marker also
// counts the complete lines omitted, with their line-number range when text is numbered. It
// reports false when the tail has no line boundary.
func cutLines(text, head string, bound, headSize int) (string, bool) {
	first, last, isNumbered := numberedRange(text)
	total := strconv.Itoa(len(text))
	width := len("\n[... " + total + " lines, " + total + " bytes omitted ...]\n")
	if isNumbered {
		z := strconv.Itoa(last)
		width = len("\n[... " + total + " lines (" + z + "-" + z + "), " + total + " bytes omitted ...]\n")
	}
	tailSize := bound - headSize - width
	if tailSize < 0 {
		return "", false
	}
	tail := validSuffix(text[len(text)-tailSize:])
	i := strings.IndexByte(tail, '\n')
	if i < 0 {
		return "", false
	}
	tail = tail[i+1:]
	middle := text[len(head) : len(text)-len(tail)]
	lines := strings.Count(middle, "\n")
	unit := "lines"
	if lines == 1 {
		unit = "line"
	}
	var marker string
	if isNumbered {
		a := first + strings.Count(head, "\n")
		marker = fmt.Sprintf("\n[... %d %s (%d-%d), %d bytes omitted ...]\n", lines, unit, a, a+lines-1, len(middle))
	} else {
		marker = fmt.Sprintf("\n[... %d %s, %d bytes omitted ...]\n", lines, unit, len(middle))
	}
	return head + marker + tail, true
}

// numberedRange reports whether every line of text begins with a decimal number (no leading zeros,
// at least 1) and a tab, each one more than the line before, with the first and last numbers.
func numberedRange(text string) (first, last int, ok bool) {
	rest := text
	for len(rest) > 0 {
		line := rest
		if i := strings.IndexByte(rest, '\n'); i >= 0 {
			line, rest = rest[:i], rest[i+1:]
		} else {
			rest = ""
		}
		digits := 0
		for digits < len(line) && line[digits] >= '0' && line[digits] <= '9' {
			digits++
		}
		if digits == 0 || digits > 18 || line[0] == '0' || digits == len(line) || line[digits] != '\t' {
			return 0, 0, false
		}
		n, _ := strconv.Atoi(line[:digits])
		if last != 0 && n != last+1 {
			return 0, 0, false
		}
		if first == 0 {
			first = n
		}
		last = n
	}
	return first, last, last != 0
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
