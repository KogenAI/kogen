package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"kogen-loop/api"
)

// TestLoopPin keeps the in-tree kogen-loop copy exactly what loop-pin.json names: the digest
// over its files and the protocol/library ids Kogen was built against
// (docs/executor-contract.md §7). Change both only through packaging/sync-kogen-loop.sh.
func TestLoopPin(t *testing.T) {
	raw, err := os.ReadFile("loop-pin.json")
	if err != nil {
		t.Fatal(err)
	}
	var pin struct {
		Module, Protocol, Library, Digest string
		Files                             int
	}
	if err := json.Unmarshal(raw, &pin); err != nil {
		t.Fatal(err)
	}
	if pin.Module != "kogen-loop" || pin.Protocol != api.Protocol || pin.Library != api.Library {
		t.Fatalf("pin %s %s %s, compiled kogen-loop %s %s", pin.Module, pin.Protocol, pin.Library, api.Protocol, api.Library)
	}
	root := filepath.Join("third_party", "kogen-loop")
	var files []string
	err = filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		rel, _ := filepath.Rel(root, p)
		files = append(files, filepath.ToSlash(rel))
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	slices.Sort(files)
	h := sha256.New()
	for _, f := range files {
		b, err := os.ReadFile(filepath.Join(root, f))
		if err != nil {
			t.Fatal(err)
		}
		s := sha256.Sum256(b)
		h.Write([]byte(f + "\x00" + hex.EncodeToString(s[:]) + "\n"))
	}
	if got := hex.EncodeToString(h.Sum(nil)); got != pin.Digest || len(files) != pin.Files {
		t.Fatalf("third_party/kogen-loop digest %s over %d files, pin %s over %d: run packaging/sync-kogen-loop.sh",
			got, len(files), pin.Digest, pin.Files)
	}
}
