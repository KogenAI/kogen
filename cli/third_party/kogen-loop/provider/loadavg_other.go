//go:build !linux && !darwin

package provider

// readLoadAverage has no source on this platform.
func readLoadAverage() ([3]float64, bool) { return [3]float64{}, false }
