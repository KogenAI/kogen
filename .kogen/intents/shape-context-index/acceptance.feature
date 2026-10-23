Feature: Bounded native Shape repository navigation
  Background:
    Given the exact Shape index source packet:
      """
      # Shape context index — native request

      Native slug: `shape-context-index`. Product: Kogen core (this repository). Kogen Shape investigates and decides the design, specifications and tests. This request supplies human originals and measured facts only.

      ## Exact human originals (highest authority)

      ### human-steering-06.txt (scope of the Go migration this unblocks)
      everything
      Rewriting whatever is in Elixir in Kogen to Go

      ### human-steering-09.txt (excerpt)
      Kogen shas to investigate everything it can't be retarded like that :/

      ### human-steering-14.txt
      Almir, 22 October 2026 (exact user message):

      I won't be there to check on you tonight, so please have some kind of 30 minute interval check for how it's going. But still, the old rules apply: you shouldn't interfere if possible and if you do make sure the Kogen is fixed so you don't have to in the future.

      ## Measured facts (operator observation, not design)

      - On installed `kogen 44c2e06d`, a real native Shape of the large `go-core-migration` request (ChatGPT `gpt-6.1-sol` high) ran 1553 s and 64 responses with 11 Shape working-window resets. It then stopped honestly: `candidate/context_budget_exceeded: Shape complete next request 586149 bytes; mandatory 435251; ceiling 524288; reserve 131072 tokens`, with exact unsent input retained in custody.
      - In that unsent input, the first (mandatory, never-reset) user message is 247586 bytes. Its `# Protection contract` section contains a `Context index:` JSON (directories and files of this repository at the current tree) of about 188 KB. The request text itself is about 17 KB; README and testing-rules sections are a few KB each. The next largest items were the reset handoff (80580 bytes) and the package submission function call (51940 bytes).
      - The 524288-byte ceiling and 131072-token reserve are delivered guarantees and must stay. Shape working windows (`44c2e06d`) cannot reduce mandatory material. Kogen's own repository has grown (many Intents, spec features, step files), so its index scales with the repository. Large repositories therefore leave little room for large Shapes.
      - Evidence: `/Users/almirsarajcic/Areas/Kogen/studio-work/provider-subscriptions-20261022/go-migration-native/shape-2/`. The irreducible stop archive is `native-working-context-custody/12.json` there.

      ## Boundaries
      - Keep the ceiling/reserve guard, full rendered measurement, authority (exact request, Q&A, README, testing rules, protection/automatic baseline) and their non-clipping, the inspection and documentation gates and evidence, source provenance, readiness identity and reviewer independence. Repository facts remain discoverable by Shape's own tools.
      - Deterministic tests use local fixtures only. Make no universal claim that every request fits, and do not split Intents automatically.
      - Out of scope: the Go migration itself, providers, caching, Studio, workers, release, deployment.
      """

  Scenario: Answered native Shape uses navigation without weakening authority
    When I exercise native Shape index mode "answers" with 0 inventory files and 0 extra reads
    Then the Shape index contract observations are:
      | observation                         | expected |
      | status                              | 0        |
      | navigation shape and identity       | true     |
      | descriptor maximum bytes            | 1024     |
      | exact authority                     | true     |
      | exact question and answer           | true     |
      | inspection refused before reads     | true     |
      | fabricated documentation refused    | true     |
      | list search and read reached source | true     |
      | actual readiness ran                | true     |
      | exact provenance and readiness      | true     |
      | no approval or Git mutation         | true     |
      | all sent requests within ceiling    | true     |

  Scenario: Repository cardinality no longer consumes mandatory Shape context
    When I exercise native Shape index mode "large" with 1800 inventory files and 0 extra reads
    Then the Shape index contract observations are:
      | observation                         | expected |
      | status                              | 0        |
      | navigation shape and identity       | true     |
      | descriptor maximum bytes            | 1024     |
      | exact authority                     | true     |
      | inspection refused before reads     | true     |
      | fabricated documentation refused    | true     |
      | list search and read reached source | true     |
      | inventory absent from mandatory     | true     |
      | actual readiness ran                | true     |
      | exact provenance and readiness      | true     |
      | no approval or Git mutation         | true     |
      | all sent requests within ceiling    | true     |

  Scenario: A completed-boundary window retains the compact descriptor
    When I exercise native Shape index mode "windows" with 0 inventory files and 40 extra reads
    Then the Shape index contract observations are:
      | observation                         | expected |
      | status                              | 0        |
      | navigation shape and identity       | true     |
      | descriptor maximum bytes            | 1024     |
      | exact authority                     | true     |
      | a real working window reset         | true     |
      | archives bind exact mandatory       | true     |
      | reset measures actual rendered body | true     |
      | actual readiness ran                | true     |
      | exact provenance and readiness      | true     |
      | no approval or Git mutation         | true     |
      | all sent requests within ceiling    | true     |

  Scenario: Compact navigation does not make irreducible authority sendable
    When I exercise native Shape index mode "irreducible" with 0 inventory files and 0 extra reads
    Then the Shape index contract observations are:
      | observation                         | expected |
      | status                              | 1        |
      | Shape provider request count        | 0        |
      | navigation shape and identity       | true     |
      | exact authority                     | true     |
      | honest budget stop                  | true     |
      | exact unsent input custody          | true     |
      | no publication                      | true     |
      | no approval or Git mutation         | true     |
