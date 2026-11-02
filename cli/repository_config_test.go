package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/KogenAI/kogen-coordinator/project"
)

func TestLoadConfigOfTheRepository(t *testing.T) {
	// The configuration this repository itself uses must stay readable.
	root := filepath.Join("..")
	if _, err := os.Stat(filepath.Join(root, project.ConfigPath)); err != nil {
		t.Skip("not inside the Kogen repository")
	}
	if _, err := project.LoadConfig(root); err != nil {
		t.Fatal(err)
	}
}
