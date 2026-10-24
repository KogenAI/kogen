// Command kogen is Kogen: one Go program (spec chapter 09). It parses the command line, reads
// the caller's input and runs every command in this process: the read-only commands, sign-in
// with its loopback listener, init, and shaping, approving and building Intents. Project
// commands run through package sys, each in its own process group.
package main

import (
	"crypto/sha256"
	"fmt"
	"io"
	"kogen/build"
	"kogen/sys"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"unicode/utf8"
)

const topPage = `Commands:
  context    Read checkout-local facts (JSON)
  completion zsh  Print standalone Zsh completion
  init       Prepare this Git repository for Kogen
  intent     Shape, approve and build an Intent
  provider   Sign in to a provider and show logins
  uninstall  Remove the installed kogen
  version    Show the Kogen version
  help       List commands

Run kogen <command> to see its subcommands and options.
`

const intentPage = `Usage: kogen intent <command> <slug> [arguments] [options]

Commands:
  shape <slug> <file|->     Shape an Intent from a request file (- reads stdin)
  refine <slug> <sha256> <file|->  Correct existing files; require fresh approval
  approve <slug> [<hash>]   Show the review card, or approve the Intent
  build <slug>              Build, verify, review and commit the approved Intent
  recover <build-id> --output <directory>  Preserve a protected blocker and clear implementation only
  resume <build-id>         Continue a stopped Build in this checkout
  list                     List packages and Build attempts
  usage [run-id]          Explain local retained provider usage
  inspect <run-id>         Inspect recorded Build evidence
  preflight <slug>         Observe read-only prerequisites

Options:
  --project <checkout>  Project checkout (default: current directory)
  --by <name>           Approver (default: your Git identity)
  --context <file>      Fresh Build diagnostic data only (not resume)
  --output <directory>  Recover only: NEW directory outside the checkout (required)
`

const providerPage = `Usage: kogen provider <command>

Commands:
  login chatgpt            Sign in with a ChatGPT account
  login supergrok          Sign in with a SuperGrok subscription
  login opencode-go        Save your OpenCode Go workspace key from stdin
  login anthropic          Save your Anthropic API key privately from stdin
  login openai-compatible  Save an optional key for an OpenAI-compatible host from stdin
  list [--json]            Show local logins and official compatibility

Logins belong to this machine, never to a repo.
`

var pages = map[string]string{"top": topPage, "intent": intentPage, "provider": providerPage}

// invocation is a parsed command line.
type invocation struct {
	provider string
	json     bool
	command  string // init, shape, refine, approve, build, login, list, uninstall, version
	slug     string
	file     string
	hash     string
	by       string
	project  string
	context  *string
	output   string
}

type usageError struct{ msg, page string }

// spec describes one leaf command: its path, options and positional names.
type spec struct {
	path       string
	command    string
	page       string
	options    []string
	positional []string // required names, e.g. "<slug>"
	optional   int      // number of trailing optional positionals
}

var leaves = map[string]spec{
	"init":           {path: "init", command: "init", page: "top"},
	"uninstall":      {path: "uninstall", command: "uninstall", page: "top"},
	"version":        {path: "version", command: "version", page: "top"},
	"intent shape":   {path: "intent shape", command: "shape", page: "intent", options: []string{"project"}, positional: []string{"<slug>", "<file|->"}},
	"intent refine":  {path: "intent refine", command: "refine", page: "intent", options: []string{"project"}, positional: []string{"<slug>", "<sha256>", "<file|->"}},
	"intent approve": {path: "intent approve", command: "approve", page: "intent", options: []string{"project", "by"}, positional: []string{"<slug>", "<hash>"}, optional: 1},
	"intent recover": {path: "intent recover", command: "recover", page: "intent", options: []string{"project", "output"}, positional: []string{"<build-id>"}},
	"intent resume":  {path: "intent resume", command: "resume", page: "intent", options: []string{"project"}, positional: []string{"<build-id>"}},
	"intent build":   {path: "intent build", command: "build", page: "intent", options: []string{"project", "context"}, positional: []string{"<slug>"}},
	"provider login": {path: "provider login", command: "login", page: "provider", positional: []string{"<provider>"}},
	"provider list":  {path: "provider list", command: "list", page: "provider", options: []string{"json"}},
}

var hashRe = regexp.MustCompile(`^[0-9a-f]{6,64}$`)
var slugRe = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*$`)

// parse returns the invocation, or a help page to print (exit 0), or a usage error (CLI-2).
func parse(args []string) (*invocation, string, *usageError) {
	if len(args) == 0 {
		return nil, topPage, nil
	}
	if len(args) == 1 {
		switch args[0] {
		case "--help", "-h":
			return nil, topPage, nil
		case "--version":
			return &invocation{command: "version"}, "", nil
		}
	}
	var leaf spec
	var rest []string
	switch args[0] {
	case "help":
		if len(args) == 2 && isHelpFlag(args[1]) {
			return nil, topPage, nil
		}
		if len(args) > 1 {
			return nil, "", &usageError{fmt.Sprintf("kogen help: unexpected argument '%s'", args[1]), "top"}
		}
		return nil, topPage, nil
	case "intent", "provider":
		group := args[0]
		if len(args) == 1 {
			return nil, pages[group], nil
		}
		if len(args) == 2 && isHelpFlag(args[1]) {
			return nil, pages[group], nil
		}
		l, ok := leaves[group+" "+args[1]]
		if !ok {
			return nil, "", &usageError{fmt.Sprintf("kogen %s: unknown command '%s'", group, args[1]), group}
		}
		leaf, rest = l, args[2:]
	case "init", "uninstall", "version":
		leaf, rest = leaves[args[0]], args[1:]
	default:
		return nil, "", &usageError{fmt.Sprintf("kogen: unknown command '%s'", args[0]), "top"}
	}

	fail := func(format string, a ...any) (*invocation, string, *usageError) {
		return nil, "", &usageError{fmt.Sprintf("kogen "+leaf.path+": "+format, a...), leaf.page}
	}
	opts := map[string]string{}
	var pos []string
	endOpts := false
	for i := 0; i < len(rest); i++ {
		tok := rest[i]
		switch {
		case endOpts || tok == "-" || !strings.HasPrefix(tok, "-"):
			pos = append(pos, tok)
		case tok == "--":
			endOpts = true
		case isHelpFlag(tok) && i == len(rest)-1:
			return nil, pages[leaf.page], nil
		case !strings.HasPrefix(tok, "--"):
			return fail("unknown option '%s'", tok)
		default:
			name, value, hasValue := strings.Cut(tok[2:], "=")
			if !contains(leaf.options, name) {
				return fail("unknown option '--%s'", name)
			}
			if name == "json" && !hasValue {
				opts[name] = "true"
				continue
			}
			if !hasValue {
				if i+1 >= len(rest) {
					return fail("--%s needs a value", name)
				}
				i++
				value = rest[i]
			}
			opts[name] = value
		}
	}
	if len(pos) < len(leaf.positional)-leaf.optional {
		return fail("missing %s", leaf.positional[len(pos)])
	}
	if len(pos) > len(leaf.positional) {
		return fail("unexpected argument '%s'", pos[len(leaf.positional)])
	}
	inv := &invocation{json: opts["json"] == "true", command: leaf.command, project: opts["project"], by: opts["by"]}
	if value, ok := opts["context"]; ok {
		inv.context = &value
	}
	if leaf.command == "recover" {
		if opts["output"] == "" {
			return fail("missing --output <directory>")
		}
		inv.output = opts["output"]
	}
	switch leaf.command {
	case "login":
		inv.provider = pos[0]
		if pos[0] != "chatgpt" && pos[0] != "supergrok" && pos[0] != "opencode-go" && pos[0] != "anthropic" && pos[0] != "openai-compatible" {
			return fail("unknown provider '%s' (supported: chatgpt, supergrok, opencode-go, anthropic, openai-compatible)", pos[0])
		}
	case "shape":
		inv.slug, inv.file = pos[0], pos[1]
	case "refine":
		inv.slug, inv.hash, inv.file = pos[0], pos[1], pos[2]
		if len(inv.hash) != 64 || !hashRe.MatchString(inv.hash) {
			return fail("<sha256> must be 64 lowercase hex characters")
		}
	case "build", "resume", "recover":
		inv.slug = pos[0]
	case "approve":
		inv.slug = pos[0]
		if len(pos) == 2 {
			if !hashRe.MatchString(pos[1]) {
				return fail("<hash> must be 6 to 64 lowercase hex characters")
			}
			inv.hash = pos[1]
		}
	}
	return inv, "", nil
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

func isHelpFlag(tok string) bool {
	return tok == "--help" || tok == "-h"
}

func main() {
	sys.MaybeSupervise(os.Args[1:])
	sys.EnableSupervisor()
	os.Exit(run(os.Args[1:], installRoot))
}

// run is one kogen invocation and returns its exit code. locate finds the installation root
// for the commands that need it.
func run(args []string, locate func() (string, error)) int {
	if handled, code := localRead(args); handled {
		return code
	}
	inv, page, uerr := parse(args)
	if uerr != nil {
		fmt.Print(uerr.msg + "\n\n" + pages[uerr.page])
		return 2
	}
	if inv == nil {
		fmt.Print(page)
		return 0
	}
	root, err := locate()
	if err != nil {
		return exitFor(err)
	}
	// LOOP-11: project commands get Kogen's own Node (INS-4) and its bundled Cucumber (SET-13).
	if node, err := os.ReadFile(filepath.Join(root, "node-path")); err == nil {
		os.Setenv("KOGEN_NODE", strings.TrimSpace(string(node)))
	}
	os.Setenv("KOGEN_CUCUMBER", filepath.Join(root, "lib", "cucumber", "node_modules"))
	os.Setenv("KOGEN_QUINT", filepath.Join(root, "lib", "quint", "node_modules", "@informalsystems", "quint", "dist", "src", "cli.js"))
	if inv.command == "uninstall" {
		return exitFor(uninstall(root))
	}
	if code, ok := runNative(inv, root); ok {
		return code
	}
	return prepare(inv, root)
}

// prepare validates what the Intent commands and init need from the command line and the
// caller's files, then runs the command and returns its exit code.
func prepare(inv *invocation, root string) int {
	cwd, err := os.Getwd()
	if err != nil {
		return exitFor(sys.Fail("environment", "cwd_unavailable", err.Error(), 3))
	}
	job := engineJob{inv: inv, root: root}
	if inv.context != nil {
		job.diagnostic, err = readDiagnostic(cwd, *inv.context)
		if err != nil {
			return exitFor(sys.Fail("intent", "context_unavailable", err.Error(), 2))
		}
	}
	switch inv.command {
	case "shape", "refine", "approve", "build", "resume", "recover":
		if inv.command != "resume" && inv.command != "recover" && (!slugRe.MatchString(inv.slug) || len(inv.slug) < 3 || len(inv.slug) > 48) {
			return exitFor(sys.Fail("intent", "invalid_slug", "Slug must be 3 to 48 characters and use lowercase letters, digits and dashes.", 2))
		}
		job.project = cwd
		if inv.project != "" {
			job.project = absFrom(cwd, inv.project)
			if st, err := os.Stat(job.project); err != nil || !st.IsDir() {
				return exitFor(sys.Fail("environment", "project_unavailable", job.project, 3))
			}
		}
		if inv.command == "recover" {
			job.output = absFrom(cwd, inv.output)
		}
		if inv.command == "shape" || inv.command == "refine" {
			if job.request, err = readRequest(cwd, inv.file); err != nil {
				return exitFor(err)
			}
			if inv.file != "-" {
				job.requestPath = absFrom(cwd, inv.file)
			}
		}
	case "init":
		job.project = cwd
	}
	if inv.command == "shape" || inv.command == "refine" || inv.command == "build" || inv.command == "resume" {
		if err := checkSeams(); err != nil {
			return exitFor(err)
		}
	}
	return runEngine(job)
}

func absFrom(cwd, p string) string {
	if filepath.IsAbs(p) {
		return filepath.Clean(p)
	}
	return filepath.Join(cwd, p)
}

// readRequest reads the request (or the answers) from a file or stdin (SHP-1).
func readRequest(cwd, file string) (string, error) {
	name := "stdin"
	var data []byte
	var err error
	if file == "-" {
		data, err = io.ReadAll(os.Stdin)
	} else {
		name = absFrom(cwd, file)
		data, err = os.ReadFile(name)
		if os.IsNotExist(err) {
			return "", sys.Fail("intent", "request_unavailable", name+": not found", 2)
		}
	}
	if err != nil {
		return "", sys.Fail("intent", "request_unavailable", name+": unreadable", 2)
	}
	if strings.TrimSpace(string(data)) == "" {
		return "", sys.Fail("intent", "request_unavailable", name+": empty", 2)
	}
	return string(data), nil
}

var seamRe = regexp.MustCompile(`^http://(127\.0\.0\.1|localhost):[0-9]+$`)

// checkSeams accepts only loopback test URLs (GPT-11).
func checkSeams() error {
	for _, name := range []string{"KOGEN_PROVIDER_URL", "KOGEN_AUTH_URL"} {
		if v, ok := os.LookupEnv(name); ok && !seamRe.MatchString(v) {
			return sys.Fail("environment", "invalid_test_seam", name+" must be http://127.0.0.1:<port> or http://localhost:<port>", 3)
		}
	}
	return nil
}

// installRoot is <prefix>/lib/kogen: the folder holding bin/kogen, found through symlinks (INS-3).
func installRoot() (string, error) {
	self, err := os.Executable()
	if err == nil {
		self, err = filepath.EvalSymlinks(self)
	}
	if err != nil {
		return "", sys.Fail("environment", "installation_damaged", "cannot locate the kogen program: "+err.Error()+"; reinstall Kogen", 3)
	}
	return filepath.Dir(filepath.Dir(self)), nil
}

// uninstall removes <prefix>/lib/kogen and the <prefix>/bin/kogen link (INS-5).
func uninstall(root string) error {
	prefix := filepath.Dir(filepath.Dir(root))
	link := filepath.Join(prefix, "bin", "kogen")
	target, err := filepath.EvalSymlinks(link)
	if filepath.Base(root) != "kogen" || filepath.Base(filepath.Dir(root)) != "lib" || err != nil || target != filepath.Join(root, "bin", "kogen") {
		return sys.Fail("environment", "not_installed", "this kogen runs from "+root+", not from an installation made by install.sh", 3)
	}
	if err := os.Remove(link); err != nil {
		return sys.Fail("environment", "uninstall_failed", err.Error(), 3)
	}
	if err := os.RemoveAll(root); err != nil {
		return sys.Fail("environment", "uninstall_failed", err.Error(), 3)
	}
	fmt.Print("Uninstalled kogen from " + prefix + "\n")
	fmt.Print("Kept your ChatGPT, SuperGrok, OpenCode Go, Anthropic and OpenAI-compatible logins; remove it with: rm -f ~/.kogen/credentials/chatgpt.json ~/.kogen/credentials/chatgpt.lock ~/.kogen/host-id ~/.kogen/credentials/supergrok.json ~/.kogen/credentials/supergrok.lock ~/.kogen/credentials/opencode-go.json ~/.kogen/credentials/opencode-go.lock ~/.kogen/credentials/anthropic.json ~/.kogen/credentials/anthropic.lock ~/.kogen/credentials/openai-compatible.json ~/.kogen/credentials/openai-compatible.lock\n")
	return nil
}

// validateDiagnostic counts original bytes.
func validateDiagnostic(data []byte) bool {
	return len(data) <= 262144 && utf8.Valid(data) && strings.TrimSpace(string(data)) != ""
}

func readDiagnostic(cwd, file string) (*build.Diagnostic, error) {
	path := absFrom(cwd, file)
	st, err := os.Stat(path)
	if err != nil || !st.Mode().IsRegular() {
		return nil, fmt.Errorf("file must be readable and regular")
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("file is unreadable")
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, 262145))
	if err != nil || !validateDiagnostic(data) {
		return nil, fmt.Errorf("file must contain nonblank UTF-8 data of at most 262144 bytes")
	}
	return &build.Diagnostic{Text: string(data), SourcePath: path, SHA256: fmt.Sprintf("%x", sha256.Sum256(data))}, nil
}
