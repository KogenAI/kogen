package main

import (
	"strings"
	"testing"
)

func TestHelpDispatchDoesNotLocateRuntime(t *testing.T) {
	for path := range helpPages {
		for _, flag := range []string{"--help", "-h"} {
			args := append(strings.Fields(path), flag)
			if code := run(args, func() (string, error) { t.Fatalf("runtime lookup for %v", args); return "", nil }); code != 0 {
				t.Fatalf("%v: exit %d", args, code)
			}
			for _, flags := range [][]string{{flag, "--not-a-kogen-option"}, {"--not-a-kogen-option", flag}} {
				args = append(strings.Fields(path), flags...)
				if code := run(args, func() (string, error) { t.Fatalf("runtime lookup for %v", args); return "", nil }); code != 2 {
					t.Fatalf("%v: exit %d", args, code)
				}
			}
		}
	}
}

func TestHelpPreservesOptionTerminator(t *testing.T) {
	inv, page, err := parse([]string{"intent", "shape", "feature", "--", "--help"})
	if err != nil || page != "" || inv == nil || inv.file != "--help" {
		t.Fatalf("terminator: %+v %q %v", inv, page, err)
	}
}

func TestHelpDoesNotHideUnknownSubcommand(t *testing.T) {
	for _, group := range []string{"intent", "provider", "completion"} {
		for _, flag := range []string{"--help", "-h"} {
			args := []string{group, "nonsense", flag}
			if code := run(args, func() (string, error) { t.Fatalf("runtime lookup for %v", args); return "", nil }); code != 2 {
				t.Fatalf("%v: exit %d", args, code)
			}
		}
	}
}

func TestHelpDocumentsNonzeroWorkflowExits(t *testing.T) {
	for _, path := range []string{"init", "intent shape", "intent approve", "intent build", "provider login"} {
		text := commandHelp(path)
		for _, code := range []string{"4 provider", "5 refusal"} {
			if !strings.Contains(text, code) {
				t.Fatalf("%s: missing %s", path, code)
			}
		}
	}
}
