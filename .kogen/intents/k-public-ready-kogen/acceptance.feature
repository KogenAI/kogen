Feature: kogen reads correctly as a public repository
  The public tree carries no runner or home paths, host names or personal names outside the
  out-of-scope files; Intent records keep what they say with neutral placeholders; the README
  serves a public reader; every Markdown link resolves publicly.

  Background:
    Given the public-ready scan leaves out these paths, where a trailing slash marks a folder:
      | .kogen/project.yaml         |
      | cli/third_party/kogen-loop/ |
      | cli/loop-pin.json           |
      | cli/go.mod                  |
      | cli/go.sum                  |

  Scenario: No runner or home path, host name or personal name remains in the tree
    When the public-ready scan reads every text file in the tree
    Then the public-ready scan read at least 800 files, including:
      | README.md                                            |
      | docs/evidence/bundled-zip-safety/receipts/runtime.txt |
      | .kogen/intents/go-core-migration/intent.md           |
      | .kogen/intents/k-public-ready-kogen/intent.md        |
      | features/steps/k5_loop_repin_steps.js                |
    And the public-ready scan finds no home path, runner path, host name or personal name

  Scenario: Intent records keep what they say with path placeholders
    Then the public-ready file ".kogen/intents/k-go-test-parallel/intent.md" contains:
      """
      candidate diff at <work>/k-go-test-parallel-5308fb40.diff selectively
      """
    And the public-ready file ".kogen/intents/k-pin-knobs/intent.md" contains:
      """
      clean checkout <home>/src/loop-1b8ef1f, now detached at
      """
    And the public-ready file ".kogen/intents/k5b-loop-repin-ksafe/intent.md" contains:
      """
      `sh packaging/sync-kogen-loop.sh <home>/src/kogen-loop`
      """
    And the public-ready file ".kogen/intents/k-probe-mix-home/intent.md" contains:
      """
      `MIX_HOME=<home>/.mix`
      """
    And the public-ready file ".kogen/intents/k-probe-mix-home/intent.md" contains:
      """
      `<work>/src/s-browser-waits/.kogen/local/shaping/s-browser-waits/events.ndjson`
      """
    And the public-ready file ".kogen/intents/k-pin-test-mac-path/intent.md" contains:
      """
      TMPDIR `/var/folders/.../T/`
      """
    And the public-ready file ".kogen/intents/reopen-blocked-review/acceptance.feature" contains:
      """
      uses retained executable "<home>/Areas/Kogen/studio-work/kogen-dev/failfast-c3ee2a8e/bin/kogen"
      """

  Scenario: Intent records keep what they say with host and owner placeholders
    Then the public-ready file ".kogen/intents/k-hung-check/intent.md" contains:
      """
      (laptop <host>, kogen 5d93641
      """
    And the public-ready file ".kogen/intents/k-review-verdict-strand/intent.md" contains:
      """
      retrieval from <host>:~/logs/s-mcp-invites-run-c8de4b13/log.jsonl
      """
    And the public-ready file ".kogen/intents/k-pin-test-mac-path/intent.md" contains:
      """
      Studio runner evidence (<host>, tree 298d8a8
      """
    And the public-ready file ".kogen/intents/all-provider-cache-reuse/intent.md" contains:
      """
      On this host both emails are <owner-email>, global hooks are
      """
    And the public-ready file ".kogen/intents/go-core-migration/intent.md" contains:
      """
      except the two changes the owner approved:
      """
    And the public-ready file ".kogen/intents/shape-context-index/acceptance.feature" contains:
      """
      The owner, 22 October 2026 (exact user message):
      """
    And the public-ready file ".kogen/intents/k18-reset-thinking-binding/intent.md" contains:
      """
      Evidence on <host>: `<home>/src/kogen-kperf2/.kogen/local/runs/
      """
    And the public-ready file "docs/evidence/bundled-zip-safety/receipts/runtime.txt" contains:
      """
      Darwin <host> 25.6.0 Darwin Kernel Version
      """

  Scenario: Step files that share a replaced literal stay consistent with their records
    Then the public-ready file ".kogen/intents/build-continuity/acceptance.feature" contains:
      """
      1: Keep exactly — Owner Δ🙂
      """
    And the public-ready file "features/steps/build_continuity_steps.js" contains:
      """
      label: 'Keep exactly — Owner Δ🙂'
      """
    And the public-ready file "features/steps/build_continuity_steps.js" contains:
      """
      JSON.stringify(r.answers).includes('Owner')
      """
    And the public-ready file "features/steps/all_provider_cache_steps.js" contains:
      """
      email = cache-fixture@example.invalid
      """
    And the public-ready file "features/steps/all_provider_cache_steps.js" contains:
      """
      s.includes('<cache-fixture@example.invalid>')
      """
    And the public-ready file "features/steps/all_provider_cache_steps.js" contains:
      """
      s==='cache-fixture@example.invalid'
      """
    And the public-ready file "features/steps/k5_loop_repin_steps.js" contains:
      """
      path.join(os.homedir(), 'Areas/Kogen/delivery/kogen-loop')
      """
    And the public-ready file "features/steps/native_image_evidence_steps.js" contains:
      """
      path.join(os.homedir(), 'Areas/Kogen/studio-work/kogen-repairs/native-image-evidence-20261021')
      """
    And the public-ready file "features/steps/supergrok_subscription_steps.js" contains:
      """
      path.join(os.homedir(), 'Areas/Kogen/studio-work/provider-subscriptions-20261022/account-precheck')
      """

  Scenario: The README introduces the component to a public reader
    Then the public-ready file "docs/testing-rules.md" has SHA-256 "631f7ad0ce8283fd8147656e2d1dbc9b8b7dca7e4a32af0686f9cacbedeb817c"
    And the public-ready file "README.md" contains:
      """
      reads the key's base URL line, then the key line
      """
    And the public-ready README introduction, before its first "## " heading, contains:
      """
      https://kogen.dev
      """
    And the public-ready file "README.md" contains:
      """
      git clone https://github.com/KogenAI/kogen
      """
    And the public-ready file "README.md" contains:
      """
      cd cli && go test
      """
    And the public-ready file "README.md" contains "contact@kogen.dev" exactly once
    And the public-ready file "README.md" contains none of these:
      | Studio Build         |
      | 543748f1             |
      | KOGEN-0              |
      | 516.8 seconds        |
      | no published release |
      | No published release |
      | GOPRIVATE            |
      | insteadOf            |
      | contribut            |
      | Contribut            |
      | pull request         |
      | Pull request         |
      | open an issue        |
      | Open an issue        |

  Scenario: Links resolve publicly and nothing points into the private workspace
    Then no file named "SECURITY.md", "CONTRIBUTING.md" or "BRANDING.md" is in the tree, in any folder or letter case
    And every Markdown link in the tree outside the left-out paths resolves publicly
    And no Markdown file outside the left-out paths, ".kogen/intents/" and "docs/evidence/" mentions any of these private workspace locations:
      | studio-work/        |
      | research/benchmarks/ |
      | build-notes/        |
      | lanes-private       |
      | <home>/Areas/       |
