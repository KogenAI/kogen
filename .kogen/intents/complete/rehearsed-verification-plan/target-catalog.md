# Required target catalog

`priv/kogen/verification_targets.yaml` is the tracked project-root catalog, loaded and frozen by the controller at admission. It preserves this public target set and ordering metadata. Disposable Build fixtures supply their own catalog through the maintained test seam. Lower rank runs first after dependencies. Every non-`check` target depends on `check`; the Stop plan records `check` only once.

| target | cost class | rank | provider-backed | rehearsal identity | owner |
| --- | --- | ---: | --- | --- | --- |
| `check` | offline-complete | 0 | no | none | `scripts/check/offline.py` |
| `cold-offline` | offline-cold | 50 | no | none | `test/kogen/cold_offline_test.exs` |
| `live-general` | provider-focused | 100 | yes | `rehearse-live-general` | independent semantic Reviewer challenge moved from `test/kogen/live_test.exs` |
| `live-shaping-quality` | provider-evaluation | 200 | yes | `rehearse-live-shaping-quality` | `test/kogen/live_shaping_evaluation_test.exs` |
| `live-native` | provider-native | 300 | yes | `rehearse-live-native` | native distribution, compatibility, and native-helper owners |
| `live-reviewer-rework` | provider-lifecycle | 400 | yes | `rehearse-live-reviewer-rework` | `Kogen.LiveReviewerReworkTest`, moved to its own owner file |
| `live-shape-to-build` | provider-end-to-end | 500 | yes | `rehearse-live-shape-to-build` | `Kogen.LiveShapeToBuildTest` in its own owner file |

Ranks describe deterministic expected cost/dependency policy, not historical timing guarantees. A catalog completeness test derives declared verification targets from Make and rejects missing entries, extra/orphaned entries, duplicate ranks/identities where prohibited, invalid dependencies, and every aggregate alias. A controller needing all boundaries expands these six non-`check` targets explicitly; the catalog exposes no aggregate target.

Every provider-backed entry uses the executable rehearsal object and trace contract in `rehearsal-design.md`; a string identity or selector alone is invalid. It declares production preparation, selection, schema, consumer, audit, and settlement entry points, paired fixtures, exact command, and trace assertions. Implementation source and runtime traces are the executable oracle inspected by `check`.
