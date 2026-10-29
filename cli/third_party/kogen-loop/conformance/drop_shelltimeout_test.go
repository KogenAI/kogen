package conformance

import (
	"reflect"
	"testing"

	"kogen-loop/provider"
	"kogen-loop/tools"
)

// The per-call shell time limit is deleted, not replaced; the other caller options stay.
func TestShellTimeoutRemoved(t *testing.T) {
	if _, ok := reflect.TypeOf(tools.Tools{}).FieldByName("ShellTimeout"); ok {
		t.Error("tools.Tools.ShellTimeout must be removed")
	}
	for _, c := range []struct {
		typ   reflect.Type
		field string
	}{
		{reflect.TypeOf(provider.Client{}), "ResponseBudget"},
		{reflect.TypeOf(provider.Request{}), "Single"},
	} {
		if _, ok := c.typ.FieldByName(c.field); !ok {
			t.Errorf("%s.%s must remain", c.typ, c.field)
		}
	}
}
