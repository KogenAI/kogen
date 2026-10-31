// Package footprint lets package tools tell the engine which files a call touches, without
// a new exported surface on tools. Package tools sets Of when it is initialised.
package footprint

import "strings"

// Footprint is what a call reads and writes. Paths are absolute and free of symlinks.
// Barrier means the effects are unknown or opaque: the call is ordered against every other.
type Footprint struct {
	Barrier       bool
	Reads, Writes []string
}

// Of analyses a call of the *tools.Tools t (typed any to keep this package free of imports).
var Of func(t any, name string, args map[string]any) Footprint

// Overlap reports whether the two footprints can interfere: a barrier on either side, or a
// write that equals, contains or is contained by anything the other touches.
func Overlap(a, b Footprint) bool {
	if a.Barrier || b.Barrier {
		return true
	}
	for _, w := range a.Writes {
		if hits(w, b.Reads) || hits(w, b.Writes) {
			return true
		}
	}
	for _, w := range b.Writes {
		if hits(w, a.Reads) {
			return true
		}
	}
	return false
}

func hits(p string, set []string) bool {
	for _, q := range set {
		if within(p, q) || within(q, p) {
			return true
		}
	}
	return false
}

// within reports whether p is q or below it, comparing components. Case is ignored: on a
// case-insensitive file system two spellings are one file, and serializing distinct files is
// merely slower.
func within(p, q string) bool {
	pp, qq := strings.Split(p, "/"), strings.Split(q, "/")
	if len(pp) < len(qq) {
		return false
	}
	for i, c := range qq {
		if c != "" && !strings.EqualFold(pp[i], c) {
			return false
		}
	}
	return true
}
