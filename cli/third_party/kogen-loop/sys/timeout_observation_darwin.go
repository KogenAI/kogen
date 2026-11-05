//go:build darwin

package sys

// The numeric group query includes unreaped zombies. Size queries reserve slack;
// only the actual length from a successful data query proves absence.
func timeoutGroupAlive(pgid int) (bool, error) {
	records, err := groupRecords(pgid)
	if err != nil {
		return false, err
	}
	return len(records) != 0, nil
}
