package provider

import "math"

// loadAverage is the host's 1, 5 and 15 minute load averages as three numbers rounded to two
// decimals, or nil where the host gives none or the read fails. It is read as an attempt starts.
func loadAverage() any {
	v, ok := readLoadAverage()
	if !ok {
		return nil
	}
	out := make([]float64, 3)
	for i, x := range v {
		if math.IsNaN(x) || math.IsInf(x, 0) || x < 0 {
			return nil
		}
		out[i] = math.Round(x*100) / 100
	}
	return out
}
