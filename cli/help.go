package main

import (
	"fmt"
	"strings"
)

type helpInfo struct{ usage, purpose, arguments, options, prerequisites, changes, next string }

var helpPages = map[string]helpInfo{
	"init":             {"", "Prepare a repository for Kogen.", "None.", "None.", "A clean committed Git tree, Git identity and provider login.", "Writes and commits .kogen/project.yaml and .kogen/models.yaml.", "kogen intent shape <slug> <file>"},
	"uninstall":        {"", "Remove the installed Kogen.", "None.", "None.", "An installation made by install.sh.", "Removes the installation and Kogen's Claude Code runtime; retains logins.", "kogen help"},
	"version":          {"", "Show the Kogen version.", "None.", "None.", "None.", "None.", "kogen help"},
	"context":          {"[--json] [--project DIR]", "Read checkout-local facts as JSON.", "None.", "--json; --project DIR (default: current directory).", "None.", "None.", "kogen intent list"},
	"completion":       {"<command>", "Show completion commands.", "command: zsh.", "None.", "None.", "None.", "kogen completion zsh"},
	"completion zsh":   {"", "Print standalone Zsh completion.", "None.", "None.", "None.", "None.", "kogen help"},
	"intent":           {"<command>", "Shape, approve and build an Intent.", "command: shape, refine, approve, build, recover, resume, list, usage, inspect or preflight.", "See each command's help.", "None.", "None for this listing.", "kogen intent shape --help"},
	"provider":         {"<command>", "Manage provider logins.", "command: login or list.", "See each command's help.", "None.", "None for this listing.", "kogen provider login --help"},
	"provider login":   {"<provider>", "Sign in to a provider.", "provider: chatgpt, supergrok, opencode-go, anthropic, claude-code or openai-compatible.", "None.", "ChatGPT or SuperGrok account for browser login; claude-code signs in with Kogen's Claude Code on an interactive terminal (installing its pinned runtime when missing), and piped claude-code input is storage only; other providers read credentials from stdin (openai-compatible reads base URL then key).", "Stores a local login, outside the repository.", "kogen provider list"},
	"provider list":    {"[--json]", "Show local logins and official compatibility.", "None.", "--json: output JSON.", "None.", "None.", "kogen init"},
	"intent shape":     {"<slug> <file|-> [--project DIR]", "Shape an Intent from a request.", "slug: Intent name; file: request, or - for stdin.", "--project DIR (default: current directory).", "An initialized project and provider login.", "Writes Intent files and local shaping evidence.", "kogen intent approve <slug>"},
	"intent refine":    {"<slug> <sha256> <file|-> [--project DIR]", "Correct an existing Intent.", "slug: Intent name; sha256: full lowercase hash; file: feedback, or - for stdin.", "--project DIR (default: current directory).", "An existing Intent and provider login.", "Changes Intent files and requires fresh approval.", "kogen intent approve <slug>"},
	"intent approve":   {"<slug> [<hash>] [--by NAME] [--project DIR]", "Show the review card or approve an Intent.", "slug: Intent name; hash: optional card hash.", "--by NAME (default: Git identity); --project DIR (default: current directory).", "An existing Intent.", "Records readiness evidence and, when a hash is supplied, approval.", "kogen intent build <slug>"},
	"intent build":     {"<slug> [--project DIR] [--context FILE]", "Build, verify, review and commit an approved Intent.", "slug: Intent name.", "--project DIR (default: current directory); --context FILE: fresh diagnostic data.", "A clean committed project, current approval and provider login.", "Writes implementation and evidence and commits a successful Build.", "kogen intent inspect <run-id>"},
	"intent resume":    {"<build-id> [--project DIR]", "Continue a stopped Build.", "build-id: stopped Build identifier.", "--project DIR (default: current directory).", "A resumable Build and provider login.", "Continues implementation, verification, review and potentially commits.", "kogen intent inspect <run-id>"},
	"intent recover":   {"<build-id> --output DIR [--project DIR]", "Preserve a protected blocker and clear implementation only.", "build-id: blocked Build identifier.", "--output DIR: required new directory outside checkout; --project DIR (default: current directory).", "A protected blocked Build.", "Writes recovery evidence and clears implementation state.", "kogen intent refine <slug> <sha256> <file>"},
	"intent list":      {"[--json] [--project DIR] [--limit N] [--cursor CURSOR]", "List Intent packages and Build attempts.", "None.", "--json; --project DIR (default: current directory); --limit N (1..100, default: 20); --cursor CURSOR.", "An initialized project.", "None.", "kogen intent inspect <run-id>"},
	"intent inspect":   {"<run-id> [--json] [--project DIR]", "Inspect recorded Build evidence.", "run-id: Build identifier.", "--json; --project DIR (default: current directory).", "An initialized project with recorded evidence.", "None.", "kogen intent list"},
	"intent preflight": {"<slug> [--json] [--project DIR]", "Observe read-only prerequisites.", "slug: Intent name.", "--json; --project DIR (default: current directory).", "An initialized project.", "None.", "kogen intent build <slug>"},
	"intent usage":     {"[run-id] [options]", "Explain local retained provider usage.", "run-id: optional Build identifier.", "--project DIR (default: current directory); --json; --lineage (requires run-id); --limit N (1..100, default: 20); --slug, --phase, --role, --model, --effective-model, --effort, --effective-effort, --outcome, --pass, --repair, --since, --until filters; --group-by (default: phase,role; fields: project,slug,lineage,phase,role,model,effective-model,effort,effective-effort,outcome,pass,repair). Times use UTC RFC3339.", "An initialized project.", "None.", "kogen intent list"},
}

func commandHelp(path string) string {
	h := helpPages[path]
	suffix := ""
	if h.usage != "" {
		suffix = " " + h.usage
	}
	return fmt.Sprintf("Usage: kogen %s%s\n\nPurpose: %s\nArguments: %s\nOptions: %s\n  --help, -h: Show this help.\nPrerequisites: %s\nChanges: %s\nExit codes: 0 success; 1 operation failed; 2 invalid arguments; 3 environment error; 4 provider failure; 5 refusal or action required; signals use 128 plus signal number.\nNext: %s\n", path, suffix, h.purpose, h.arguments, h.options, h.prerequisites, h.changes, h.next)
}

// helpDispatch handles help before local reads or runtime lookup, while scanning all options.
func helpDispatch(args []string) (bool, int) {
	if len(args) == 0 {
		return false, 0
	}
	path, n := args[0], 1
	if len(args) > 1 && (path == "intent" || path == "provider" || path == "completion") {
		if _, ok := helpPages[path+" "+args[1]]; ok {
			path += " " + args[1]
			n = 2
		} else if !strings.HasPrefix(args[1], "-") {
			return false, 0
		}
	}
	if _, ok := helpPages[path]; !ok {
		return false, 0
	}
	rest := args[n:]
	allowed := map[string]bool{}
	for _, x := range helpOptions(path) {
		allowed[x] = true
	}
	hasHelp := false
	end := false
	for i := 0; i < len(rest); i++ {
		a := rest[i]
		if end {
			continue
		}
		if a == "--" {
			end = true
			continue
		}
		if isHelpFlag(a) {
			hasHelp = true
			continue
		}
		if strings.HasPrefix(a, "--") {
			name, _, eq := strings.Cut(strings.TrimPrefix(a, "--"), "=")
			if allowed[name] && !eq && name != "json" && name != "lineage" && i+1 < len(rest) {
				i++
			}
		}
	}
	if !hasHelp {
		return false, 0
	}
	end = false
	for i := 0; i < len(rest); i++ {
		a := rest[i]
		if end {
			continue
		}
		if a == "--" {
			end = true
			continue
		}
		if isHelpFlag(a) {
			continue
		}
		if strings.HasPrefix(a, "-") && a != "-" {
			name, _, eq := strings.Cut(strings.TrimPrefix(a, "--"), "=")
			if !strings.HasPrefix(a, "--") || !allowed[name] {
				fmt.Printf("kogen %s: unknown option '%s'\n", path, a)
				return true, 2
			}
			if !eq && name != "json" && name != "lineage" && i+1 < len(rest) {
				i++
			}
		}
	}
	fmt.Print(commandHelp(path))
	return true, 0
}

func helpOptions(path string) []string {
	if leaf, ok := leaves[path]; ok {
		return leaf.options
	}
	switch path {
	case "context", "intent inspect", "intent preflight":
		return []string{"project", "json"}
	case "intent list":
		return []string{"project", "json", "limit", "cursor"}
	case "intent usage":
		return []string{"project", "json", "lineage", "limit", "slug", "phase", "role", "model", "effective-model", "effort", "effective-effort", "outcome", "pass", "repair", "since", "until", "group-by"}
	}
	return nil
}
