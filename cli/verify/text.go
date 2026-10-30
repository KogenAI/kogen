// Package verify runs Kogen's verification passes and readiness checks: fixers, the exact
// clean candidate materialized in a scratch directory, setup, the Intent's acceptance
// scenarios accounted against their Cucumber Messages report (VER-3, VER-4), its Quint model
// (VER-5), the project's checks with fail-fast and `not_run` (VER-6), mutation guards (VER-9),
// and the readiness evidence of an Intent: dry runs, declared feasibility evidence, cached
// and current checks (SHP-8, AUT-1, AUT-2). Every command runs through sys.Session with stdin
// closed and the caller's environment.
package verify

import (
	"encoding/json"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"kogen/project"
)

// Excerpt is command output for feedback that keeps both ends: Quint names its error at the
// start and its location and summary at the end. Up to 60 lines whole, else the first 30
// and the last 20 (VER-5).
func Excerpt(output string) string {
	lines := strings.Split(trimTrailing(output), "\n")
	if len(lines) <= 60 {
		return strings.Join(lines, "\n")
	}
	out := slices.Clone(lines[:30])
	out = append(out, fmt.Sprintf("[... %d lines omitted ...]", len(lines)-50))
	out = append(out, lines[len(lines)-20:]...)
	return strings.Join(out, "\n")
}

// Diagnostic is the excerpt of a command's output that a refusal shows and a diagnostic
// keeps: the Excerpt line policy, then the 16 KiB bound of Cut, so one enormous line cannot
// grow it. Redact first: a cut must never split a secret.
func Diagnostic(output string) string { return Cut(Excerpt(output)) }

// Tail is the last n lines of command output.
func Tail(output string, n int) string {
	lines := strings.Split(trimTrailing(output), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}

func trimTrailing(s string) string { return strings.TrimRightFunc(s, unicode.IsSpace) }

// maxText is the longest text a tool result or feedback block keeps (LOOP-8).
const maxText = 16384

// Cut bounds text to 16 KiB: the first 4 KiB and the last part, with the number of omitted
// bytes between, both cut at UTF-8 boundaries.
func Cut(text string) string {
	if len(text) <= maxText {
		return text
	}
	marker := func(n int) string { return fmt.Sprintf("\n[... %d bytes omitted ...]\n", n) }
	head := validPrefix(text[:4096])
	tailSize := 12288 - len(marker(len(text)))
	tail := validSuffix(text[len(text)-tailSize:])
	return head + marker(len(text)-len(head)-len(tail)) + tail
}

// logLimit is the longest output the run log records.
const logLimit = 1 << 20

// Cap is command output as recorded in the run log: at most 1 MiB, the middle cut out.
func Cap(text string) string {
	if len(text) <= logLimit {
		return text
	}
	const marker = "\n[... cut in the run log ...]\n"
	size := (logLimit - len(marker)) / 2
	return validPrefix(text[:size]) + marker + validSuffix(text[len(text)-size:])
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

// shellQuote single-quotes s for /bin/sh.
func shellQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

// encode is compact JSON the way Kogen writes it: keys in byte order, no HTML escaping.
func encode(v any) string {
	b, err := project.EncodeJSON(v)
	if err != nil {
		b, err = json.Marshal(v)
		if err != nil {
			panic(err)
		}
	}
	return string(b)
}

// generic round-trips v through JSON, giving the values a JSON file would hold.
func generic(v any) any {
	var out any
	d := json.NewDecoder(strings.NewReader(encode(v)))
	d.UseNumber()
	if err := d.Decode(&out); err != nil {
		panic(err)
	}
	return out
}

func itoa(n int) string { return strconv.Itoa(n) }

// shellWords splits a command line exactly as Elixir's OptionParser.split does: only the
// space character separates words; a quote opens a quoted part that the same quote closes
// (inside it a backslash before that quote drops the backslash; every other backslash stays);
// outside quotes a backslash before a space or a quote drops the backslash. A trailing empty
// word is dropped. An unclosed quote is an error, as it is a crash in Kogen.
func shellWords(line string) ([]string, error) {
	var words []string
	var buf []byte
	var quote byte
	s := strings.TrimLeft(line, " ")
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '\\' && quote != 0 && i+1 < len(s) && s[i+1] == quote:
			buf = append(buf, quote)
			i++
		case quote == 0 && (c == '"' || c == '\''):
			quote = c
		case quote != 0 && c == quote:
			quote = 0
		case quote == 0 && c == '\\' && i+1 < len(s) && (s[i+1] == ' ' || s[i+1] == '\'' || s[i+1] == '"'):
			buf = append(buf, s[i+1])
			i++
		case quote == 0 && c == ' ':
			words = append(words, string(buf))
			buf = nil
			for i+1 < len(s) && s[i+1] == ' ' {
				i++
			}
		default:
			buf = append(buf, c)
		}
	}
	if quote != 0 {
		return nil, fmt.Errorf("argv string did not terminate properly, a %c was opened but never closed", quote)
	}
	if len(buf) > 0 {
		words = append(words, string(buf))
	}
	return words, nil
}
