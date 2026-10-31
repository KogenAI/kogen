package shape

import (
	"fmt"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"kogen/verify"
)

func budgetFiles(good, bad string) map[string]any {
	files := shpFiles()
	declaration := fmt.Sprintf(`- evidence: {"id":"observer","kind":"observer","inputs":[],"observers":["features/steps/is_even_steps.js"],"checks":[{"name":"good","command":%q,"exit":0,"output":""},{"name":"bad","command":%q,"exit":143,"output":""}]}`, good, bad)
	entries := files["files"].([]any)
	entries[0].(map[string]any)["content"] = strings.Replace(shpIntentMD, "- none\n", declaration+"\n", 1)
	return files
}

func assertNoReadyOnRetry(t *testing.T, f *shpFx) {
	t.Helper()
	var calls atomic.Int32
	f.Prov.route = func(_ map[string]any) *shpStep {
		n := calls.Add(1)
		if n == 2 && f.exists(".kogen/local/readiness/is-even.json") {
			t.Error("timed-out submission recorded reusable readiness")
		}
		return nil
	}
}

func TestShapeFeasibilityFitsLimit(t *testing.T) {
	serialTmp(t)
	production, restore := verify.ContractProbeDeadline(time.Second, nil)
	defer restore()
	if production != 300*time.Second {
		t.Fatalf("probe limit %v", production)
	}
	for _, which := range []string{"good", "bad"} {
		t.Run(which, func(t *testing.T) {
			good, bad := "true", "exit 143"
			if which == "good" {
				good = "sleep 60"
			} else {
				bad = "sleep 60"
			}
			f := newShpFx(t, shpSubmit("slow", budgetFiles(good, bad)), shpAck("waive"), shpSubmit("fixed", budgetFiles("true", "exit 143")), shpAck("ack"))
			assertNoReadyOnRetry(t, f)
			exit, err := f.shape("Add calc.is_even(n).")
			if err != nil || exit != 0 {
				t.Fatalf("exit %d err %v stderr %s req %v", exit, err, f.Stderr, []any{shpOutputs(f.Prov.requests()[1]), shpOutputs(f.Prov.requests()[2])})
			}
			req := f.Prov.requests()
			for _, i := range []int{1, 2} {
				output := fmt.Sprint(shpOutputs(req[i]))
				shpContains(t, "timeout feedback", output, "observer/"+which)
				shpContains(t, "limit", output, "300-second")
			}
			if !f.exists(".kogen/local/readiness/is-even.json") {
				t.Fatal("corrected candidate did not publish readiness")
			}
		})
	}
}

func TestShapeTimelyEvidenceFitsLimit(t *testing.T) {
	serialTmp(t)
	_, restore := verify.ContractProbeDeadline(2*time.Second, nil)
	defer restore()
	f := newShpFx(t, shpSubmit("timely", budgetFiles("sleep 1.2", "sleep 1.2; exit 143")), shpAck("ack"))
	exit, err := f.shape("Add calc.is_even(n).")
	if err != nil || exit != 0 {
		t.Fatalf("exit %d err %v stderr %s req %v", exit, err, f.Stderr, []any{shpOutputs(f.Prov.requests()[1]), shpOutputs(f.Prov.requests()[2])})
	}
	if !f.exists(".kogen/local/readiness/is-even.json") {
		t.Fatal("no readiness")
	}
}

func TestShapeAcceptanceFitsLimit(t *testing.T) {
	serialTmp(t)
	production, restore := verify.ContractShapeAcceptanceDeadline(10 * time.Second)
	defer restore()
	if production != 120*time.Second {
		t.Fatalf("acceptance limit %v", production)
	}
	f := newShpFx(t, shpSubmit("slow", shpFiles()), shpAck("retry"), shpAck("ack"))
	script := f.read("accept.sh")
	script = strings.Replace(script, "if [ -f '", fmt.Sprintf("if [ ! -f '%s/blocked' ]; then touch '%s/blocked'; sleep 60; fi\nif [ -f '", f.Aux, f.Aux), 1)
	f.write("accept.sh", script)
	assertNoReadyOnRetry(t, f)
	exit, err := f.shape("Add calc.is_even(n).")
	if err != nil || exit != 0 {
		t.Fatalf("exit %d err %v stderr %s req %v", exit, err, f.Stderr, []any{shpOutputs(f.Prov.requests()[1]), shpOutputs(f.Prov.requests()[2])})
	}
	feedback := shpOutputs(f.Prov.requests()[1])["slow"]
	shpContains(t, "acceptance", feedback, "acceptance timed out")
	shpContains(t, "limit", feedback, "120-second")
	if !f.exists(".kogen/local/readiness/is-even.json") {
		t.Fatal("corrected acceptance did not publish readiness")
	}
}

func TestShapeTimelyAcceptanceFitsLimit(t *testing.T) {
	serialTmp(t)
	_, restore := verify.ContractShapeAcceptanceDeadline(30 * time.Second)
	defer restore()
	for _, status := range []string{"PASSED", "FAILED"} {
		t.Run(status, func(t *testing.T) {
			f := newShpFx(t, shpSubmit("submit", shpFiles()), shpAck("ack"))
			if status == "PASSED" {
				f.setReport(status, 0)
			}
			exit, err := f.shape("Add calc.is_even(n).")
			if err != nil || exit != 0 {
				t.Fatalf("exit %d err %v stderr %s req %v", exit, err, f.Stderr, []any{shpOutputs(f.Prov.requests()[1]), shpOutputs(f.Prov.requests()[2])})
			}
			if !f.exists(".kogen/local/readiness/is-even.json") {
				t.Fatal("no readiness")
			}
		})
	}
}
