# live-native prepare_fixture probe (Shaping root, 2026-09-26)

Clone of main 98ebcfb2 (probe/prepare/kogen). The command:

    KOGEN_CODEX_ROOT=<scratch>/native-root PATH=test/support:$PATH \
      mix run --no-start -e '{:ok, cfg} = Kogen.Intent.read_config(".kogen/config.yaml", "codex");
      Kogen.Codex.Compatibility.prepare_fixture(File.cwd!(), cfg)'

Result:
- It returned `{:ok, fixture, evidence, discovery}`, with discovery keys `home`,
  `hook_marker`, `marker`, `ok`, `personal_sentinel`, `project_sentinel` and `xdg`.
- It took about 1 s after compile.
- No provider shim was invoked: the denial receipt was never written.
- It created `compatibility-<epoch>-<n>/{fixture,fixture-hostile-home}` under the
  given root and left them in place. It has no cleanup of its own.

Conclusions:
- live-native's `prepare` is Kogen.Codex readiness (`Kogen.Codex.open`, the
  environment class) plus `prepare_fixture` under a disposable
  `KOGEN_CODEX_ROOT`, which `prepare` then removes.
- It never writes into the real Kogen Codex store.
