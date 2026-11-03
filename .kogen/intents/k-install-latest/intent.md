# Find the Latest release without the GitHub API

Slug: k-install-latest
Model: not applicable — a one-shot lookup with one fallback and a fixed failure message; no state persists between runs
Acceptance:
- .kogen/intents/k-install-latest/acceptance.feature
- features/steps/k_install_latest_steps.js
- features/steps/k_install_latest_fake.cjs
- features/steps/k_install_latest_good.sh
- features/steps/k_install_latest_bad.sh

Fix `packaging/install-kogen.sh` so the documented one-line install, `curl -fsSL https://github.com/KogenAI/kogen/releases/latest/download/install-kogen.sh | sh`, works when the unauthenticated GitHub API is rate limited (60 requests an hour per IP). It failed on a fresh home with "curl: (56) The requested URL returned error: 403" and "install-kogen: could not find the latest release", because the installer resolved Latest only through `https://api.github.com/repos/KogenAI/kogen/releases/latest`.

Without `--version` (and so without `--from`), the installer now resolves the Latest tag first from the redirect `https://github.com/KogenAI/kogen/releases/latest`, whose final URL ends in `/releases/tag/<version>`, and asks the GitHub API only when that fails. Each way is asked at most once, with no retry. It still resolves one exact version once and then downloads exactly `https://github.com/KogenAI/kogen/releases/download/<version>/kogen-<version>-<platform>.tar.gz` and `.../download/<version>/SHA256SUMS`, as now. The checksum check, extraction, `install.sh --prefix` and the final `kogen version` stay unchanged. `--version`, `--prefix` and `--from` are unchanged: with `--version`, neither the redirect nor the API is asked. What is replaced: the API stops being the only way, and the single message "could not find the latest release" becomes a message that names each way's cause and the `--version` workaround.

The interface the Build must keep for the tests:
- Redirect lookup: `curl` is given the literal argument `https://github.com/KogenAI/kogen/releases/latest`. Follow the redirect (for example `curl -sL -o /dev/null -w '%{http_code} %{url_effective}'`) or read its `Location`. The version is the part of the final URL after the last `/releases/tag/`. It must be nonempty and must not contain `/`, and the final response must be HTTP 200 (or the 3xx `Location` when the redirect is not followed). Real GitHub answers `HTTP/2 302` with `location: https://github.com/<owner>/<repo>/releases/tag/<tag>`. Do not require the final URL's scheme or host to be `https://github.com`, and pass no protocol-restricting curl options (`--proto`, `--proto-redir`): the acceptance fakes serve the redirect from `http://127.0.0.1:<port>/KogenAI/kogen/releases/tag/<version>`.
- API fallback: `curl` is given the literal argument `https://api.github.com/repos/KogenAI/kogen/releases/latest`. On HTTP 200, the version is the `tag_name` string of the JSON body. The real body is pretty-printed JSON with `"tag_name": "<tag>"` on its own line. A rate-limited answer is HTTP 403 with a JSON `message` "API rate limit exceeded for …" and `x-ratelimit-remaining: 0`.
- Only curl is used, and only these two URLs plus the two download URLs. The script stays POSIX sh, run as `curl … | sh`: no command may consume the script's stdin. The tests pipe the script to `sh -s`. There are no new flags and no new dependency.
- When both ways fail, the installer prints these lines on stdout, in this order (the existing message style), and exits 1 without downloading anything:
  1. `install-kogen: could not find the latest release`
  2. `install-kogen: https://github.com/KogenAI/kogen/releases/latest <cause>`
  3. `install-kogen: https://api.github.com/repos/KogenAI/kogen/releases/latest <cause>`
  4. `install-kogen: to install a chosen release instead, pass its tag from https://github.com/KogenAI/kogen/releases with --version, for example: curl -fsSL https://github.com/KogenAI/kogen/releases/latest/download/install-kogen.sh | sh -s -- --version <tag>`

  Here `<cause>` is `answered HTTP <status>` for a final non-2xx HTTP status (the last response's status, for example `answered HTTP 503`), `could not be reached (curl exit <n>)` when no HTTP response arrived, and `did not name a release tag` for a 2xx answer without a usable tag. `<tag>` is printed literally. curl's own diagnostics may also appear.

The files `features/steps/k_install_latest_good.sh` and `k_install_latest_bad.sh` are test-only observer control fixtures (known-good and known-bad installers). `packaging/release.sh` copies only `packaging/install-kogen.sh`, so they are never shipped. The Build changes `packaging/install-kogen.sh` and no protected file.

## Decisions
- Without --version, the installer asks the github.com/KogenAI/kogen/releases/latest redirect first and takes the version from the final URL ending in /tag/<version> (source: request)
- The GitHub API stays as a fallback, asked only when the redirect gives no tag; when the redirect works the API is not asked at all (source: request)
- One exact version is resolved once; that version's archive and SHA256SUMS are downloaded once each; --version, --prefix and --from are unchanged (source: request)
- When both ways fail, the message names each way's URL and cause (HTTP status, unreachable, or no tag) and the --version workaround with the exact one-line example above; exit status stays 1 and output stays on stdout (source: request)
- POSIX sh and curl only; no new flags; no new dependency (source: request)

## Source comparison
- Addressed: the reported failure (API answered 403, so "could not find the latest release") is reproduced by scenario 1 (redirect works, API 403) and must now install.
- Addressed: "resolves the Latest tag in a way that is not subject to the API rate limit: the github.com/KogenAI/kogen/releases/latest redirect (its final URL ends in /tag/<version>)" is the first lookup; scenario 1 asserts the API is asked 0 times.
- Addressed: "The API may stay as a fallback" is kept as the fallback; scenario 2 (redirect 503, API tag) installs through it.
- Addressed: "resolves one exact version once and downloads that version's archive and SHA256SUMS, as now": scenarios 1 and 2 assert releases/latest asked exactly once and the only downloads are `/KogenAI/kogen/releases/download/v9.9.9-test/kogen-v9.9.9-test-<platform>.tar.gz` and `.../SHA256SUMS`, once each.
- Addressed: "When both ways fail, the message names the cause and the --version workaround": scenario 3 (redirect 503, API 403) asserts the four exact lines in order, exit 1, nothing downloaded or installed.
- Addressed: "--version, --prefix and --from are unchanged": no change; the existing k-rel-releases scenario installs with --from --version --prefix.
- Addressed: "POSIX sh and curl only, as now; no new dependency; no new flags": stated in the interface; the fixtures use only sh and curl.
- Addressed: "Tests use a local fake of the redirect and the API (no network)": `k_install_latest_fake.cjs` serves 127.0.0.1 fakes behind a `curl` wrapper on PATH that rewrites https://github.com and https://api.github.com and refuses every other URL; proxies and the user's HOME are excluded.
- Literal preserved: the one-line install command, `https://github.com/KogenAI/kogen/releases/latest`, `https://api.github.com/repos/KogenAI/kogen/releases/latest`, the 60-per-hour unauthenticated limit, the message prefix `install-kogen: could not find the latest release`.
- Omitted: the original report's curl `(56)` wording; curl's own diagnostics are allowed but not required.

## Tests
- Without --version, the Latest tag comes from the releases/latest redirect even when the API answers 403, and the archive and SHA256SUMS of that one version are downloaded once each: acceptance scenario "the releases/latest redirect finds Latest while the API answers 403" reproducing the reported failure (regression)
- When the redirect fails, the API's tag_name still installs that version: acceptance scenario "the GitHub API still finds Latest when the redirect fails" (scenario)
- When both ways fail, exit 1, nothing downloaded, and the four lines naming each cause and the --version workaround: acceptance scenario "when both ways fail the message names each cause and the --version workaround" (scenario)
- --version, --prefix and --from installs are unchanged: the k-rel-releases scenario "install-kogen.sh installs the host archive from local files" (existing)

## Feasibility
- Real GitHub behavior was observed with curl 8.7.1 on 3 Nov 2026 against a public repository (cli/cli). `curl -sSI https://github.com/cli/cli/releases/latest` answered `HTTP/2 302` with `location: https://github.com/cli/cli/releases/tag/v2.103.3`. `curl -sS -o /dev/null -w '%{http_code} %{url_effective}' -L` printed `200 https://github.com/cli/cli/releases/tag/v2.103.3`. The API `https://api.github.com/repos/cli/cli/releases/latest` answered HTTP 200 with pretty-printed JSON and `x-ratelimit-limit: 60`. The fakes serve these shapes.
- Scratch run of this acceptance feature with only its step file: against the unchanged installer, 3 scenarios failed for the missing feature. Redirect case: exit 1, only the API asked, output "could not find the latest release". Fallback case: the redirect was never asked. Both-fail case: the cause lines were missing. Against `k_install_latest_good.sh` copied over the installer, 3 scenarios and 22 steps passed in about 2 s. A dry run with every `features/steps/*.js` found no undefined or ambiguous step.
- evidence: {"id":"install-latest-observer","kind":"observer","inputs":["features/steps/k_install_latest_fake.cjs","features/steps/k_install_latest_good.sh","features/steps/k_install_latest_bad.sh"],"observers":["features/steps/k_install_latest_fake.cjs"],"checks":[{"name":"good","command":"node features/steps/k_install_latest_fake.cjs control features/steps/k_install_latest_good.sh","exit":0,"output":"accepted\n"},{"name":"bad","command":"node features/steps/k_install_latest_fake.cjs control features/steps/k_install_latest_bad.sh","exit":1,"output":"rejected\nredirect: the GitHub API was asked 1 time(s), expected 0\nfallback: github.com/KogenAI/kogen/releases/latest was asked 0 time(s), expected 1\nboth-fail: missing output line (in this order) \"install-kogen: https://api.github.com/repos/KogenAI/kogen/releases/latest answered HTTP 403\"\n"}]}
