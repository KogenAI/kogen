# Cleanup amendment probe

This is an evidence-local, non-gate probe for the existing
`Kogen.IsolatedCase.run/3` collection and readiness behavior. It does not
modify production, test, Approved, Candidate, tracking, or gate files.

## Commands and results

Baseline owner test:

```sh
mix test test/kogen/isolation_cleanup_test.exs --no-start
```

Result: exit 0; `4 passed` in 2.5 s. The owner test passes when run alone.

Probe source: `cleanup_probe.exs`. It has two isolated tests. Both sleep for a
configured delay, write an externally visible marker, then remain alive so the
collection timeout invokes the real supervisor cancellation and cleanup path.

The original v1 source is retained as `cleanup_probe_v1.exs`. The first
executed v1 invocation below is retained as a failed/corrected attempt. Its
command text does pass `env` to `run/3`; the earlier report's claim that it
omitted `env` was inaccurate. The exact parent/child environment state behind
the later `System.EnvError` is not inferred here. Mix's parent ExUnit autorun
was also left enabled:

```sh
mix run --no-start -e 'Code.require_file("test/test_helper.exs"); source = Path.expand(".kogen/runtime/build-diagnostics/gEELGTWs_StA0ZFraHgiWw64/amendment-probes/cleanup/cleanup_probe.exs"); Code.require_file(source); marker = Path.join(Path.dirname(source), "missing-marker-#{System.unique_integer([:positive])}.pid"); result = Kogen.IsolatedCase.run(source, "test delayed marker without readiness", collection_timeout: 2_000, env: [{"PROBE_DELAY_MS", "3500"}, {"PROBE_MARKER", marker}]); IO.inspect(%{result: result, marker: marker, marker_exists_after_return: File.exists?(marker)})'
```

Result: the explicit call returned timeout, but the subsequent unintended
autorun failed both probe tests with `System.EnvError` for missing
`PROBE_DELAY_MS`. Correction: set `ExUnit.configure(autorun: false)` and
retain the generated marker plus both explicit `env` entries.

The v1 readiness arm wrote `PROBE_READY` before `PROBE_MARKER`. That ordering
was a race in the comparison, so `cleanup_probe.exs` was corrected while the
v1 source was retained unchanged above.

## Corrected comparison

Both corrected arms use the same 3,500 ms startup delay and 2,000 ms
collection timeout. The readiness arm writes the dependent marker first, then
the readiness marker, and uses a 7,000 ms startup bound.

Corrected no-readiness invocation:

```sh
mix run --no-start -e 'ExUnit.configure(autorun: false); Code.require_file("test/test_helper.exs"); source = Path.expand(".kogen/runtime/build-diagnostics/gEELGTWs_StA0ZFraHgiWw64/amendment-probes/cleanup/cleanup_probe.exs"); Code.require_file(source); marker = Path.join(Path.dirname(source), "corrected-missing-marker-#{System.unique_integer([:positive])}.pid"); result = Kogen.IsolatedCase.run(source, "test delayed marker without readiness", collection_timeout: 2_000, env: [{"PROBE_DELAY_MS", "3500"}, {"PROBE_MARKER", marker}]); IO.inspect(%{result: result, marker: marker, marker_exists_after_return: File.exists?(marker)})'
```

Observed transcript (exit 0):

```elixir
%{
  result: {:error, :timeout,
   "Running ExUnit with seed: 957032, max_cases: 2\nExcluding tags: [:test]\nIncluding tags: [test: :\"test delayed marker without readiness\"]\n\n\n16:03:59.941 [notice] SIGTERM received - shutting down\n\nisolated children terminated; private fixture still present\n"},
  marker: "/Users/almirsarajcic/Projects/AppBuilder/kogen/.kogen/runtime/build-diagnostics/gEELGTWs_StA0ZFraHgiWw64/amendment-probes/cleanup/corrected-missing-marker-8258.pid",
  marker_exists_after_return: false
}
```

Corrected readiness invocation:

```sh
mix run --no-start -e 'ExUnit.configure(autorun: false); Code.require_file("test/test_helper.exs"); source = Path.expand(".kogen/runtime/build-diagnostics/gEELGTWs_StA0ZFraHgiWw64/amendment-probes/cleanup/cleanup_probe.exs"); Code.require_file(source); marker = Path.join(Path.dirname(source), "corrected-ready-marker-#{System.unique_integer([:positive])}.pid"); result = Kogen.IsolatedCase.run(source, "test delayed marker with readiness", readiness: "PROBE_READY", startup_timeout: 7_000, collection_timeout: 2_000, env: [{"PROBE_DELAY_MS", "3500"}, {"PROBE_MARKER", marker}]); IO.inspect(%{result: result, marker: marker, marker_exists_after_return: File.exists?(marker), marker_contents: if(File.exists?(marker), do: File.read!(marker), else: nil)})'
```

Observed transcript (exit 0):

```elixir
%{
  result: {:error, :timeout,
   "Running ExUnit with seed: 685416, max_cases: 2\nExcluding tags: [:test]\nIncluding tags: [test: :\"test delayed marker with readiness\"]\n\n\n16:04:13.278 [notice] SIGTERM received - shutting down\n\nisolated children terminated; private fixture still present\n"},
  marker: "/Users/almirsarajcic/Projects/AppBuilder/kogen/.kogen/runtime/build-diagnostics/gEELGTWs_StA0ZFraHgiWw64/amendment-probes/cleanup/corrected-ready-marker-6020.pid",
  marker_exists_after_return: true,
  marker_contents: "marker\n"
}
```

No-readiness reproduction:

```sh
mix run --no-start -e 'ExUnit.configure(autorun: false); Code.require_file("test/test_helper.exs"); source = Path.expand(".kogen/runtime/build-diagnostics/gEELGTWs_StA0ZFraHgiWw64/amendment-probes/cleanup/cleanup_probe.exs"); Code.require_file(source); marker = Path.join(Path.dirname(source), "missing-marker-#{System.unique_integer([:positive])}.pid"); result = Kogen.IsolatedCase.run(source, "test delayed marker without readiness", collection_timeout: 2_000, env: [{"PROBE_DELAY_MS", "3500"}, {"PROBE_MARKER", marker}]); IO.inspect(%{result: result, marker: marker, marker_exists_after_return: File.exists?(marker)})'
```

Observed result (exit 0):

```elixir
%{
  result: {:error, :timeout,
   "Running ExUnit with seed: 534892, max_cases: 2\nExcluding tags: [:test]\nIncluding tags: [test: :\"test delayed marker without readiness\"]\n\n\n16:01:18.721 [notice] SIGTERM received - shutting down\n\nisolated children terminated; private fixture still present\n"},
  marker: "/Users/almirsarajcic/Projects/AppBuilder/kogen/.kogen/runtime/build-diagnostics/gEELGTWs_StA0ZFraHgiWw64/amendment-probes/cleanup/missing-marker-7494.pid",
  marker_exists_after_return: false
}
```

Readiness-controlled comparison:

```sh
mix run --no-start -e 'ExUnit.configure(autorun: false); Code.require_file("test/test_helper.exs"); source = Path.expand(".kogen/runtime/build-diagnostics/gEELGTWs_StA0ZFraHgiWw64/amendment-probes/cleanup/cleanup_probe.exs"); Code.require_file(source); marker = Path.join(Path.dirname(source), "ready-marker-#{System.unique_integer([:positive])}.pid"); result = Kogen.IsolatedCase.run(source, "test delayed marker with readiness", readiness: "PROBE_READY", startup_timeout: 3_000, collection_timeout: 500, env: [{"PROBE_DELAY_MS", "1500"}, {"PROBE_MARKER", marker}]); IO.inspect(%{result: result, marker: marker, marker_exists_after_return: File.exists?(marker), marker_contents: if(File.exists?(marker), do: File.read!(marker), else: nil)})'
```

Observed result (exit 0):

```elixir
%{
  result: {:error, :timeout,
   "Running ExUnit with seed: 321258, max_cases: 2\nExcluding tags: [:test]\nIncluding tags: [test: :\"test delayed marker with readiness\"]\n\n\n16:01:29.401 [notice] SIGTERM received - shutting down\n\nisolated children terminated; private fixture still present\n"},
  marker: "/Users/almirsarajcic/Projects/AppBuilder/kogen/.kogen/runtime/build-diagnostics/gEELGTWs_StA0ZFraHgiWw64/amendment-probes/cleanup/ready-marker-8323.pid",
  marker_exists_after_return: true,
  marker_contents: "marker\n"
}
```

## Interpretation and limits

The corrected pair demonstrates that a caller which assumes a marker exists
after a 2 s collection timeout can fail before the delayed isolated test has
created it. The readiness run waits for the real `PROBE_READY` path after the
dependent marker is created, then starts collection timing; its later timeout
still performs supervisor cleanup, and the marker is observable. This supports
a readiness-based control for startup-sensitive marker assertions.

This probe does not establish the exact production startup distribution, prove
the live failure, or select a production repair. It uses deterministic sleeps,
the real `Kogen.IsolatedCase` API, and the existing isolated supervisor. A
minimal production path to inspect is the cleanup test's marker read after
`Kogen.IsolatedCase.run/3` returns, plus the fixture startup/readiness contract;
any repair should be made by the owning Developer and validated by the proper
gate workflow. No gate, live target, provider, Stop script, or Build command
was run here.
