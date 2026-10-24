Feature: Recover stale approval cards on current main
  Historical hashes describe external evidence, not local fixture bytes.
  Trigger 1: browser-regression-load-tolerance, approved at 2026-10-23T10:36:41Z;
  old 8f13780ae096e6b0deb755af768db1a7ebc99777329135bd5d9075834a5980d6;
  fresh e5f2d8ea4eef4abce4963711da6fe51b6a9af6558edfc76151bd013cd898aef6.
  Trigger 2: guided-app-discovery, old
  b31d2e189119de588a3c1da6517b43ad4b4bcd87a3c0072db2bf089434aa54ec;
  features/steps/workspace-project-access.js changed in 73a003a0; new prefix 37897de1.
  The 22 October go-core-migration marker is represented only by a disposable legacy fixture.
  All full test hashes come from actual native local packages and receipts.
  Each fixture's approved plan has Prepare fixture (prepare), goal Keep the seeded app available,
  then Deliver fixture (deliver), goal Write the approved text; each checks test -f app.txt.

  Scenario Outline: Show and approve the current card without stale authority
    When I exercise approval card recovery "<mode>" for "<slug>"
    Then the approval recovery observations are:
      | stale Build refused without inference | true |
      | wrong approval hash preserved state   | true |
      | current card full hash                | true |
      | complete staged card                  | true |
      | stale authority visible               | true |
      | card did not replace approval         | true |
      | exact current approval                | true |
      | history retained                      | true |
      | current source bound                  | true |
      | source originals preserved            | true |
      | fresh Build landed                    | true |
      | staged Build retained                 | true |
      | independent review ran                | true |
      | new approval consumed                 | true |
    Examples:
      | mode   | slug                              |
      | parked | browser-regression-load-tolerance |
      | shared | guided-app-discovery              |

  Scenario Outline: Refine a ready unapproved package despite older authority
    When I exercise approval card recovery "<mode>" for "<slug>"
    Then the approval recovery observations are:
      | refinement succeeded       | true |
      | approval revoked           | true |
      | history retained           | true |
      | source originals preserved | true |
      | fresh approval required    | true |
      | correction retained        | true |
      | HEAD and index preserved   | true |
    Examples:
      | mode          | slug                              |
      | refine-parked | browser-regression-load-tolerance |
      | refine-shared | guided-app-discovery              |
      | legacy-refine | go-core-migration                 |

  Scenario Outline: Refuse damaged custody rather than manufacture fresh authority
    When I exercise approval card recovery "<mode>" for "guided-app-discovery"
    Then the approval recovery observations are:
      | custody refused               | true |
      | actual cause and next action   | true |
      | approval and source unchanged  | true |
      | HEAD and index preserved       | true |
      | no provider inference          | true |
    Examples:
      | mode             |
      | tampered-current |
      | missing-current  |
      | missing-history  |

  Scenario: Diagnose invalid current content instead of historical contract drift
    When I exercise approval card recovery "invalid-shared" for "guided-app-discovery"
    Then the approval recovery observations are:
      | invalid package cause         | true |
      | approval and source unchanged | true |
      | HEAD and index preserved      | true |
      | package unchanged             | true |
      | no provider inference         | true |
