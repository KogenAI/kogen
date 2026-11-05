package tools

import (
	"context"
	"strconv"
	"strings"
	"testing"
)

func TestReadFileNamesBinaryFiles(t *testing.T) {
	root := t.TempDir()
	write(t, root, "blob.bin", "a\x00b\xff\xfec")
	write(t, root, "nul.bin", "a\x00b")
	write(t, root, "latin1.txt", "caf\xe9\n")
	write(t, root, "zeros.bin", strings.Repeat("\x00", 40000))
	write(t, root, "late.bin", strings.Repeat("x\n", 10000)+"\x00")
	write(t, root, "crlf.txt", "one\r\ntwo\r\nthree")
	write(t, root, "utf8.txt", "café naïve\n日本語\n漢字 🙂\n")
	write(t, root, "empty.txt", "")
	write(t, root, "four.txt", "one\ntwo\nthree\nfour\n")
	tl := newTools(root, "read_file")
	notice := func(path string, n int) string {
		return path + ": binary file, " + strconv.Itoa(n) + " bytes (contains a NUL byte or is not valid UTF-8); content not shown"
	}
	cases := []struct {
		name string
		args map[string]any
		want string
	}{
		{"nul and invalid", map[string]any{"path": "blob.bin"}, notice("blob.bin", 6)},
		{"nul only", map[string]any{"path": "nul.bin"}, notice("nul.bin", 3)},
		{"invalid only", map[string]any{"path": "latin1.txt"}, notice("latin1.txt", 5)},
		{"zeros", map[string]any{"path": "zeros.bin"}, notice("zeros.bin", 40000)},
		{"late nul", map[string]any{"path": "late.bin"}, notice("late.bin", 20001)},
		{"binary with range", map[string]any{"path": "blob.bin", "start_line": int64(1), "end_line": int64(1)}, notice("blob.bin", 6)},
		{"crlf", map[string]any{"path": "crlf.txt"}, "1\tone\r\n2\ttwo\r\n3\tthree"},
		{"multi-byte", map[string]any{"path": "utf8.txt"}, "1\tcafé naïve\n2\t日本語\n3\t漢字 🙂"},
		{"empty", map[string]any{"path": "empty.txt"}, ""},
		{"range", map[string]any{"path": "four.txt", "start_line": int64(2), "end_line": int64(3)}, "2\ttwo\n3\tthree"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := tl.RunClassified(context.Background(), "read_file", c.args)
			if err != nil {
				t.Fatal(err)
			}
			if got.Text != c.want || got.ErrorKind != "" || got.MalformedClass != "" || got.Parts != nil {
				t.Fatalf("got %+v, want text %q", got, c.want)
			}
		})
	}
}
