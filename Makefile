.PHONY: check live-shape-to-build live-reviewer-rework live-general live-shaping-quality live-native cold-offline

# Complete offline gate. The normal Stop hook owns invoking this target.
check:
	/usr/bin/time -p python3 scripts/check/offline.py

# Provider-backed connected Shape-to-Build lifecycle.
live-shape-to-build:
	mix test --only live test/kogen/live_shape_to_build_test.exs

# Provider-backed same-Developer Reviewer rework lifecycle.
live-reviewer-rework:
	mix test --only live test/kogen/live_reviewer_rework_test.exs

# Provider-backed independent semantic Reviewer challenge.
live-general:
	mix test --only live test/kogen/live_test.exs

# Provider-backed maintained public Shaping evaluation and evidence manifest.
live-shaping-quality:
	mix test --only live test/kogen/live_shaping_evaluation_test.exs

# Provider-backed managed runtime, authenticated compatibility, and native helpers.
live-native:
	mix test --only live test/kogen/codex_native_live_test.exs test/kogen/codex_compatibility_test.exs test/kogen/native_helper_live_test.exs

# Complete provider-denied offline gate from an empty private build cache.
cold-offline:
	mix test --only live test/kogen/cold_offline_test.exs
