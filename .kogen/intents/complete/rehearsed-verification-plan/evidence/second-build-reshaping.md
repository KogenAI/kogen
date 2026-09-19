# Second failed Build reshaping evidence

Build `jJ-fpjeqdTh0FBVmI27hGzg3` exhausted two outer resumptions without acceptance. The final Reviewer satisfied cost ordering, rehearsal parity, and deterministic triage, and closed the earlier selector, rehearsal, changed-Credo, and rehearsal-resolution findings. One new finding remained:

- F5: `lib/kogen/build/guarded_paths.ex` did not force `core.filemode=true`, so an admitted repository configured with `core.filemode=false` could hide an unguarded executable-bit-only change.

The Shaper supplied the exact repair: every Git operation that determines changed paths must force `core.filemode=true`, and a negative control must configure `core.filemode=false`, change only an unguarded tracked file's executable bit, and prove rejection. The dirty Candidate remains preserved and is not proof of this repaired requirement.
