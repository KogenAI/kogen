package buildprogram

import (
	"strings"
)

// lines is n lines of exactly 50 bytes.
func lines(n int, fill string) string {
	return strings.Repeat(strings.Repeat(fill, 49)+"\n", n)
}
