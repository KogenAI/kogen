# Relationship between proposals 06 and 08

Investigated at supplied HEAD, 2026-09-13. This is advisory scope analysis, not an accepted scope decision.

08 produces five source-bound conversations and Draft histories so ordinary independent Review can assess Shaping judgment. 06 delivers and preserves every declared required artifact through child output, target receipts and Complete, independently of which files Review cites.

## Existing route and gaps

- Build validates Developer handoff before running non-check targets (build.ex:270-305). A handoff cannot cite files generated later by live.
- IsolatedCase.run! discards successful child output (test/support/isolated_case.ex:163). A child-local successful manifest assertion does not establish parent delivery.
- Target receipts keep a diagnostic output tail (build.ex:334); no optional manifest is parsed before truncation.
- Reviewer can discover runtime files and cite them. Build snapshots each cited whole file with hash and base64 contents (build.ex:587), then copies tracking into Complete (build.ex:702). This preserves cited bytes, not every required uncited file.
- Publication checks cited files remain unchanged (build.ex:760). No target-run digest currently binds uncited evidence before Review.

## Full 06 integration

Requires bounded frame forwarding through isolated dispatch; strict optional locator/manifest parsing of full target output; path, digest and duplicate validation; receipt delivery; automatic uncited artifact retention with distinct controller provenance; mutation checks through publication; an actual composed offline lifecycle regression with positive, corruption and unrelated-target controls. No new paid cases are intrinsically required for 06.

The existing prototype under optimize-kogen-execution/evidence/live-manifest-protocol is not accepted production integration. Its README describes an earlier all-files-must-be-cited design; the later target-evidence.md and closure-amendment.md replace that with automatic controller retention. Do not mistake the prototype for complete implementation of the current contract.

## Smaller alternative and its cost

A self-contained evidence file could use current whole-file citation snapshots, reducing the number of citations. It still needs reliable current-run discovery and source/attempt binding; retention remains dependent on a Reviewer citing it. Introducing guaranteed retention for it reintroduces controller work. The later historical contract explicitly rejected replacing required per-artifact coverage with a bundle. Thus this is a changed guarantee requiring a human decision, not an equivalent implementation shortcut.

## Appetite assessment

The two changes compose naturally but have different independently demonstrable outcomes. 06 can be proved with a small deterministic target containing two artifacts, one cited and one uncited, through the existing fake-provider lifecycle. 08 still needs a new five-case driver, fixtures, intermediate-turn capture, offline rehearsal and semantic live evidence: those sources are absent at this HEAD. Combining both adds Build publication correctness to already substantive Shaping evaluation work. No reliable duration estimate or claim of fitting one Developer conversation is established.
