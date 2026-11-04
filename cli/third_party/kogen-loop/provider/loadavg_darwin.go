package provider

import (
	"encoding/binary"
	"syscall"
)

// readLoadAverage reads the vm.loadavg sysctl: struct loadavg is three fixpt_t (uint32) values
// followed by fscale (long), padded to 8 bytes. Sysctl trims the trailing zero byte.
func readLoadAverage() ([3]float64, bool) {
	var v [3]float64
	s, err := syscall.Sysctl("vm.loadavg")
	if err != nil {
		return v, false
	}
	b := []byte(s)
	// The trailing zero byte may have been trimmed from the scale's high bytes and padding.
	if len(b) < 20 {
		return v, false
	}
	full := make([]byte, 24)
	copy(full, b)
	scale := binary.LittleEndian.Uint64(full[16:24])
	if scale == 0 {
		return v, false
	}
	for i := range v {
		v[i] = float64(binary.LittleEndian.Uint32(full[i*4:])) / float64(scale)
	}
	return v, true
}
