# Remote plugin isolation probe — 2026-09-29

Real Codex 0.158.0 app-server observations on the existing managed and personal login homes. Four disposable sessions ran in parallel while the Developer implemented the repair. No model turns or external app tool calls were made; no credentials were copied or login changed.

## Results

| Login home | apps/plugins | Installed apps | Enabled / callable apps | Plugin entries |
|---|---|---:|---:|---:|
| managed-off | disabled | 11 | 0 / 0 | 0 |
| managed-on | enabled | 12 | 12 / 12 | 10 |
| personal-off | disabled | 12 | 0 / 0 | 0 |
| personal-on | enabled | 12 | 12 / 12 | 18 |

Both disabled sessions returned an empty app discovery list and no installed plugin entries. Enabled controls contained actual enabled remote-source plugins, including in the managed Kogen home. Separate installation alone therefore does not suppress the account plugin inventory. The explicit apps/plugins feature flags suppress discovery and mark installed apps non-callable at this native server boundary.

## Limits and acceptance

The enabled fresh app catalog fetch timed out for the managed home and failed to send for the personal home. Positive controls are native installed app/plugin observations, not successful fresh remote catalog fetches. Installed app counts differ between snapshots; no completeness claim is made. Matching account fingerprints bind the returned account objects, not a fresh authentication proof.

This is NOT a model-visible root/helper/resume isolation receipt or whole-Build acceptance. Do not synthesize account-plugins.json claiming those contexts were observed. The production oracle must bind observations to runtime, effective flags, context and freshness, and distinguish unproven from demonstrated leakage. Keep bundled skill classification separate from account plugin exclusion.

## Reproduce / integrate

Run `python3 operations/scripts/probe-plugin-isolation.py` from the local Kogen area. The script launches the pinned executable with apps/plugins enabled or disabled, private HOME/XDG roots, existing CODEX_HOME and shell snapshots disabled. It requests app/list, app/installed, plugin/installed and account/read through initialized native app-server stdio. It has bounded waits and terminates its own process groups. Initial plugin-list attempts timed out and are not evidence of exclusion.

`summary.json` records executable and raw receipt hashes. The adjacent four result JSON files contain sanitized native responses. The maintained script is outside this evidence directory.

Attach this compact result and receipt references to build-system-fixes at the next settled Developer handoff. Do not mutate the currently frozen approved package while its Developer is running. Resume the Developer with this evidence and require honest native discovery versus root/helper/resume coverage; no blanket isolation success based on an empty supplied list.
