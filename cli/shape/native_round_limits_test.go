package shape

import (
	"context"
	"fmt"
	"testing"
)

func TestUnsupportedShapeAndRefineRoundLimits(t *testing.T) {
	for _, configured := range []bool{false, true} {
		t.Run(fmt.Sprint(configured), func(t *testing.T) {
			limits := map[string]int(nil)
			if configured {
				limits = map[string]int{"shape": 1, "review": 1}
			}
			f := newShpFx(t, shpSubmit("c1", shpFiles()), shpAck("c2"))
			f.newSession()
			exit, err := Shape(context.Background(), f.S, ShapeInput{Project: f.Root, Slug: shpSlug, Request: "Add calc.is_even(n). Non-integers raise TypeError.", Client: f.Client, NativeRoundLimits: limits})
			if err != nil || exit != 0 || len(f.Prov.requests()) != 2 || f.read(refIntentPath) != shpIntentMD {
				t.Fatalf("shape exit=%d err=%v requests=%d", exit, err, len(f.Prov.requests()))
			}
			r := newRefFx(t, refOpts{red: true}, refProbe("c0", "true"), refSubmit("c1", refIntentPath, shpIntentMD))
			r.remove(".kogen/local/readiness/is-even.json")
			r.newSession()
			exit, err = Refine(context.Background(), r.S, RefineInput{Project: r.Root, Slug: shpSlug, Hash: r.hash0, Request: "Clarify only the existing draft; preserve its executable contract.", Client: r.Client, NativeRoundLimits: limits})
			if err != nil || exit != 0 || len(r.Prov.requests()) != 2 || r.read(refIntentPath) != shpIntentMD {
				t.Fatalf("refine exit=%d err=%v requests=%d", exit, err, len(r.Prov.requests()))
			}
		})
	}
}
