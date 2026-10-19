Feature: Bundled ZIP dependency repair
  Scenario: Ship a reproducible ZIP repair without changing Quint verification
    When I inspect a freshly built ZIP repair package and isolated install
    Then the ZIP repair observations are:
      | observation                 | expected |
      | override                    | 0.6.1    |
      | isolated_zip_versions       | 0.6.1    |
      | installed_zip_versions      | 0.6.1    |
      | quint_version               | 0.33.0   |
      | isolated_lock_unchanged     | true     |
      | installed_lock_matches      | true     |
      | zip_integrity_matches_spec  | true     |
      | inventory_zip_version       | 0.6.1    |
      | inventory_zip_license       | MIT      |
      | license_text_shipped        | true     |
      | typecheck                   | true     |
      | tests                       | true     |
      | seeded_typescript_run       | true     |
      | false_invariant_refuted     | true     |
      | installed_good_card         | true     |
      | installed_false_rejected    | true     |
      | spec_checked_if_changed     | true     |

  Scenario: Refuse writes through a preexisting destination symlink
    When I compare old and freshly packaged ZIP extraction with overwrite enabled
    Then the ZIP repair observations are:
      | observation             | expected    |
      | old_version             | 0.5.18      |
      | old_refuses             | false       |
      | old_outside_sentinel    | replacement |
      | old_normal_content      | replacement |
      | packaged_version        | 0.6.1       |
      | packaged_refuses        | true        |
      | packaged_outside_sentinel | unchanged |
      | packaged_normal_content | replacement |

  Scenario: Read back refreshed advisory metadata without inventing closure
    When I read the ZIP repair evidence and refreshed official advisory snapshots
    Then the ZIP repair evidence covers these advisories:
      | id                      | historical_first_patched |
      | GHSA-7q85-xj36-vmfc     | 0.6.1                    |
      | GHSA-8238-w5pm-2374    | 0.6.1                    |
      | GHSA-c6fg-446q-cg94    | 0.6.1                    |
      | GHSA-j5f4-cc29-5x44    | 0.6.1                    |
      | GHSA-p634-w6r4-rjp2    | 0.6.1                    |
      | GHSA-rcw4-f5rp-g42v    | 0.6.1                    |
      | GHSA-vwc7-r8mq-g2x9    | null                     |
      | GHSA-xcpc-8h2w-3j85    | 0.6.0                    |
