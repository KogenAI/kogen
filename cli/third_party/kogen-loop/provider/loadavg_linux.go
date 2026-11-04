package provider

import (
	"os"
	"strconv"
	"strings"
)

// readLoadAverage reads the first three fields of /proc/loadavg.
func readLoadAverage() ([3]float64, bool) {
	var v [3]float64
	b, err := os.ReadFile("/proc/loadavg")
	if err != nil {
		return v, false
	}
	f := strings.Fields(string(b))
	if len(f) < 3 {
		return v, false
	}
	for i := range v {
		x, err := strconv.ParseFloat(f[i], 64)
		if err != nil {
			return v, false
		}
		v[i] = x
	}
	return v, true
}
