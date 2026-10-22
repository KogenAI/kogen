package main

import "testing"

func TestParseHelpPagesCLI3(t *testing.T) {
	tests := []struct {
		name string
		args []string
		want string
	}{
		{name: "implicit top page", want: `Commands:
  context    Read checkout-local facts (JSON)
  completion zsh  Print standalone Zsh completion
  init       Prepare this Git repository for Kogen
  intent     Shape, approve and build an Intent
  provider   Sign in to a provider and show logins
  uninstall  Remove the installed kogen
  version    Show the Kogen version
  help       List commands

Run kogen <command> to see its subcommands and options.
`},
		{name: "explicit top page", args: []string{"help"}, want: `Commands:
  context    Read checkout-local facts (JSON)
  completion zsh  Print standalone Zsh completion
  init       Prepare this Git repository for Kogen
  intent     Shape, approve and build an Intent
  provider   Sign in to a provider and show logins
  uninstall  Remove the installed kogen
  version    Show the Kogen version
  help       List commands

Run kogen <command> to see its subcommands and options.
`},
		{name: "intent page", args: []string{"intent"}, want: `Usage: kogen intent <command> <slug> [arguments] [options]

Commands:
  shape <slug> <file|->     Shape an Intent from a request file (- reads stdin)
  refine <slug> <sha256> <file|->  Correct existing files; require fresh approval
  approve <slug> [<hash>]   Show the review card, or approve the Intent
  build <slug>              Build, verify, review and commit the approved Intent
  resume <build-id>         Continue a stopped Build in this checkout
  list                     List packages and Build attempts
  usage [run-id]          Explain local retained provider usage
  inspect <run-id>         Inspect recorded Build evidence
  preflight <slug>         Observe read-only prerequisites

Options:
  --project <checkout>  Project checkout (default: current directory)
  --by <name>           Approver (default: your Git identity)
  --context <file>      Fresh Build diagnostic data only (not resume)
`},
		{name: "provider page", args: []string{"provider"}, want: `Usage: kogen provider <command>

Commands:
  login chatgpt      Sign in with a ChatGPT account
  login supergrok    Sign in with a SuperGrok subscription
  login opencode-go  Save your OpenCode Go workspace key from stdin
  list               Show which providers Kogen is signed in to

Logins belong to this machine, never to a repo.
`},
		{name: "long top help flag", args: []string{"--help"}, want: topPage},
		{name: "short top help flag", args: []string{"-h"}, want: topPage},
		{name: "help command help flag", args: []string{"help", "--help"}, want: topPage},
		{name: "init help flag", args: []string{"init", "--help"}, want: topPage},
		{name: "intent group help flag", args: []string{"intent", "--help"}, want: intentPage},
		{name: "intent leaf help flag", args: []string{"intent", "build", "--help"}, want: intentPage},
		{name: "provider leaf help flag", args: []string{"provider", "list", "-h"}, want: providerPage},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			inv, page, err := parse(tt.args)
			if inv != nil || err != nil {
				t.Fatalf("parse(%q) = (%+v, %q, %v), want a help page", tt.args, inv, page, err)
			}
			if page != tt.want {
				t.Fatalf("parse(%q) help bytes differ\n--- got ---\n%q\n--- want ---\n%q", tt.args, page, tt.want)
			}
		})
	}
}

func TestParseCommandTreeCLI1(t *testing.T) {
	tests := []struct {
		name string
		args []string
		want invocation
	}{
		{name: "init", args: []string{"init"}, want: invocation{command: "init"}},
		{name: "refine", args: []string{"intent", "refine", "feature", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "request.md"}, want: invocation{command: "refine", slug: "feature", hash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", file: "request.md"}},
		{name: "shape", args: []string{"intent", "shape", "feature", "request.md"}, want: invocation{command: "shape", slug: "feature", file: "request.md"}},
		{name: "approve without optional hash", args: []string{"intent", "approve", "feature"}, want: invocation{command: "approve", slug: "feature"}},
		{name: "approve with optional hash", args: []string{"intent", "approve", "feature", "abcdef"}, want: invocation{command: "approve", slug: "feature", hash: "abcdef"}},
		{name: "build", args: []string{"intent", "build", "feature"}, want: invocation{command: "build", slug: "feature"}},
		{name: "provider login", args: []string{"provider", "login", "chatgpt"}, want: invocation{command: "login", provider: "chatgpt"}},
		{name: "supergrok login", args: []string{"provider", "login", "supergrok"}, want: invocation{command: "login", provider: "supergrok"}},
		{name: "provider list", args: []string{"provider", "list"}, want: invocation{command: "list"}},
		{name: "uninstall", args: []string{"uninstall"}, want: invocation{command: "uninstall"}},
		{name: "version", args: []string{"version"}, want: invocation{command: "version"}},
		{name: "version flag", args: []string{"--version"}, want: invocation{command: "version"}},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			inv, page, err := parse(tt.args)
			if err != nil || page != "" {
				t.Fatalf("parse(%q) = (%+v, %q, %v), want command %+v", tt.args, inv, page, err, tt.want)
			}
			if inv == nil || *inv != tt.want {
				t.Fatalf("parse(%q) invocation = %+v, want %+v", tt.args, inv, tt.want)
			}
		})
	}
}

func TestParseGrammarCLI2(t *testing.T) {
	valid := []struct {
		name string
		args []string
		want invocation
	}{
		{name: "option value form", args: []string{"intent", "build", "feature", "--project", "/checkout"}, want: invocation{command: "build", slug: "feature", project: "/checkout"}},
		{name: "option equals form", args: []string{"intent", "build", "feature", "--project=/checkout"}, want: invocation{command: "build", slug: "feature", project: "/checkout"}},
		{name: "options before positionals", args: []string{"intent", "shape", "--project", "/checkout", "feature", "request.md"}, want: invocation{command: "shape", slug: "feature", file: "request.md", project: "/checkout"}},
		{name: "options after positionals", args: []string{"intent", "approve", "feature", "abcdef", "--by=Sam", "--project", "/checkout"}, want: invocation{command: "approve", slug: "feature", hash: "abcdef", by: "Sam", project: "/checkout"}},
		{name: "last repeated options win", args: []string{"intent", "approve", "feature", "--project", "first", "--by=First", "--project=last", "--by", "Last"}, want: invocation{command: "approve", slug: "feature", project: "last", by: "Last"}},
		{name: "double dash ends options", args: []string{"intent", "shape", "feature", "--", "-request.md"}, want: invocation{command: "shape", slug: "feature", file: "-request.md"}},
		{name: "lone dash is a positional", args: []string{"intent", "shape", "feature", "-"}, want: invocation{command: "shape", slug: "feature", file: "-"}},
		{name: "minimum hash length", args: []string{"intent", "approve", "feature", "abcdef"}, want: invocation{command: "approve", slug: "feature", hash: "abcdef"}},
		{name: "maximum hash length", args: []string{"intent", "approve", "feature", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}, want: invocation{command: "approve", slug: "feature", hash: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}},
	}
	for _, tt := range valid {
		t.Run(tt.name, func(t *testing.T) {
			inv, page, err := parse(tt.args)
			if err != nil || page != "" || inv == nil {
				t.Fatalf("parse(%q) = (%+v, %q, %v), want command %+v", tt.args, inv, page, err, tt.want)
			}
			if *inv != tt.want {
				t.Fatalf("parse(%q) invocation = %+v, want %+v", tt.args, inv, tt.want)
			}
		})
	}

	invalid := []struct {
		name string
		args []string
		msg  string
		page string
	}{
		{name: "unknown command", args: []string{"frobnicate"}, msg: "kogen: unknown command 'frobnicate'", page: "top"},
		{name: "first unknown command wins", args: []string{"queue", "start"}, msg: "kogen: unknown command 'queue'", page: "top"},
		{name: "unknown intent command", args: []string{"intent", "frob"}, msg: "kogen intent: unknown command 'frob'", page: "intent"},
		{name: "group command match precedes option parsing", args: []string{"intent", "--project", "/checkout"}, msg: "kogen intent: unknown command '--project'", page: "intent"},
		{name: "unknown provider command", args: []string{"provider", "frob"}, msg: "kogen provider: unknown command 'frob'", page: "provider"},
		{name: "help takes no arguments", args: []string{"help", "extra", "later"}, msg: "kogen help: unexpected argument 'extra'", page: "top"},
		{name: "unknown long option", args: []string{"intent", "build", "feature", "--detach"}, msg: "kogen intent build: unknown option '--detach'", page: "intent"},
		{name: "unknown equals option", args: []string{"intent", "build", "feature", "--detach=yes"}, msg: "kogen intent build: unknown option '--detach'", page: "intent"},
		{name: "short option", args: []string{"intent", "build", "feature", "-p", "/checkout"}, msg: "kogen intent build: unknown option '-p'", page: "intent"},
		{name: "option missing value", args: []string{"intent", "build", "feature", "--project"}, msg: "kogen intent build: --project needs a value", page: "intent"},
		{name: "option unsupported by command", args: []string{"version", "--project", "/checkout"}, msg: "kogen version: unknown option '--project'", page: "top"},
		{name: "shape missing slug", args: []string{"intent", "shape"}, msg: "kogen intent shape: missing <slug>", page: "intent"},
		{name: "shape missing file", args: []string{"intent", "shape", "feature"}, msg: "kogen intent shape: missing <file|->", page: "intent"},
		{name: "approve missing slug", args: []string{"intent", "approve"}, msg: "kogen intent approve: missing <slug>", page: "intent"},
		{name: "build missing slug", args: []string{"intent", "build"}, msg: "kogen intent build: missing <slug>", page: "intent"},
		{name: "login missing provider", args: []string{"provider", "login"}, msg: "kogen provider login: missing <provider>", page: "provider"},
		{name: "shape extra positional", args: []string{"intent", "shape", "feature", "request.md", "extra"}, msg: "kogen intent shape: unexpected argument 'extra'", page: "intent"},
		{name: "version extra positional", args: []string{"version", "extra"}, msg: "kogen version: unexpected argument 'extra'", page: "top"},
		{name: "list extra positional", args: []string{"provider", "list", "extra"}, msg: "kogen provider list: unexpected argument 'extra'", page: "provider"},
		{name: "double dash makes option-looking token positional", args: []string{"intent", "build", "feature", "--", "--project"}, msg: "kogen intent build: unexpected argument '--project'", page: "intent"},
		{name: "unknown provider", args: []string{"provider", "login", "grok"}, msg: "kogen provider login: unknown provider 'grok' (supported: chatgpt, supergrok, opencode-go)", page: "provider"},
		{name: "refine needs full hash", args: []string{"intent", "refine", "feature", "abcdef", "-"}, msg: "kogen intent refine: <sha256> must be 64 lowercase hex characters", page: "intent"},
		{name: "hash too short", args: []string{"intent", "approve", "feature", "abcde"}, msg: "kogen intent approve: <hash> must be 6 to 64 lowercase hex characters", page: "intent"},
		{name: "hash too long", args: []string{"intent", "approve", "feature", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0"}, msg: "kogen intent approve: <hash> must be 6 to 64 lowercase hex characters", page: "intent"},
		{name: "hash uppercase", args: []string{"intent", "approve", "feature", "ABCDEF"}, msg: "kogen intent approve: <hash> must be 6 to 64 lowercase hex characters", page: "intent"},
		{name: "hash non-hex", args: []string{"intent", "approve", "feature", "abcdeg"}, msg: "kogen intent approve: <hash> must be 6 to 64 lowercase hex characters", page: "intent"},
	}
	for _, tt := range invalid {
		t.Run(tt.name, func(t *testing.T) {
			inv, page, err := parse(tt.args)
			if inv != nil || page != "" || err == nil {
				t.Fatalf("parse(%q) = (%+v, %q, %v), want usage error %q", tt.args, inv, page, err, tt.msg)
			}
			if err.msg != tt.msg || err.page != tt.page {
				t.Fatalf("parse(%q) error = (%q, page %q), want (%q, page %q)", tt.args, err.msg, err.page, tt.msg, tt.page)
			}
		})
	}
}

func TestResumeGrammar(t *testing.T) {
	inv, _, err := parse([]string{"intent", "resume", "1de86a76", "--project", "/checkout"})
	if err != nil || inv.command != "resume" || inv.slug != "1de86a76" || inv.project != "/checkout" {
		t.Fatalf("resume: %+v %v", inv, err)
	}
	for _, args := range [][]string{{"intent", "resume"}, {"intent", "resume", "abc", "extra"}, {"intent", "resume", "abc", "--by", "other"}} {
		if _, _, err := parse(args); err == nil {
			t.Fatalf("accepted %v", args)
		}
	}
}
