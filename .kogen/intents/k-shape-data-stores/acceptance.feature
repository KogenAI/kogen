Feature: Shaping finds where an entity's data lives, and review checks scope against the same evidence

  The installed release runs against the scripted local provider of go_driver_support.js, in disposable fixture
  projects; no real provider, account or benchmark content is involved. The synthetic fixture keeps an account's
  memberships in db/memberships.csv, which its Account model (lib/account.js) reaches, and one export file per
  account, exports/1.json and exports/2.json, written by lib/exports.js, which the model does not reach. Every one
  of these files references the key account_id. The request is to purge a cancelled account's data.

  Scenario: Shape refuses a package that leaves files keyed by the account id uncovered and publishes the package that covers them
    When the data-stores shaper submits the package scoped to the model's associations, then the package that covers every store, and acknowledges its readiness
    Then the data-stores shape exited with status 0 after the requests "shaper, shaper, review, shaper"
    And the feedback to data-stores submission 1 was exactly:
      """
      Data stores: 3 problem(s) with where the data of the declared keys lives; nothing was published. Every file tracked at HEAD that references a key declared under ## Data stores needs an item that covers it: in scope, observed by text that acceptance.feature or a listed step file contains, or excluded by a numbered Decision that names it. Resubmitting this candidate unchanged is refused again.
      - exports/1.json references account_id (line 1); no ## Data stores item covers it
      - exports/2.json references account_id (line 1); no ## Data stores item covers it
      - lib/exports.js references account_id (lines 1, 4); no ## Data stores item covers it
      """
    And the feedback to data-stores submission 2 was readiness observations, not a refusal
    And the published data-stores package is the package that covers every store
    And the data-stores shaping events record 1 submission_refused event with gate "data_stores"
    And the first data-stores shaping request contains:
      """
      Data stores: for a request about an entity's data (for example deleting, exporting or moving an account's data), establish where that data lives before you write scope and acceptance: its schemas, the associations its model reaches, and every other store keyed by the entity's id (other tables, files, directories, indexes), found by searching the repository for each spelling of the id key. Record them in a ## Data stores section of intent.md: a line - key `<key>` for each spelling, then, for each file or directory (a path ending in /) that references a key, either - `<path>`: in scope, observed by `<text>`, where acceptance.feature or a step file listed under Acceptance contains <text>, or - `<path>`: excluded by decision <n>, where line <n> of ## Decisions names <path> and keeps its source. Shape refuses a candidate whose section leaves uncovered a file tracked at HEAD that references a declared key; the Build's independent review checks the candidate against the same scan.
      """

  Scenario: Review of a Build whose approved Intent omits the export store does not approve, and the Build stops
    When the data-stores Build runs the approved Intent that omits the export store, and its reviewer approves and then reports the omitted files
    Then the data-stores Build exited with status 1 with outcome "review_blocked" after 2 review requests
    And the first data-stores review request contains:
      """
      Data stores: when the authority has a # Data stores section, it lists every file tracked at the Build's start commit that references a key the approved Intent declares under ## Data stores, with the item that covers it. A file listed as not covered holds or reaches data the approved Intent neither scopes nor excludes by a Decision: report a blocking finding at its path, because you cannot change the approved Intent; Kogen refuses a verdict without that finding. When the approved Intent deletes, exports, moves or changes an entity's data and has no ## Data stores section, search the repository for the entity's id key yourself: a store keyed by it (another table, file, directory or index) that the Intent neither scopes nor excludes by a Decision is a blocking finding at that store's path.
      """
    And the first data-stores review request contains:
      """
      # Data stores

      Keys declared under the approved Intent's ## Data stores: account_id
      Files tracked at the Build's start commit that reference a declared key, and the item that covers each:
      - db/memberships.csv references account_id (line 1): covered by `db/memberships.csv`: in scope, observed by `db/memberships.csv`
      - exports/1.json references account_id (line 1): not covered
      - exports/2.json references account_id (line 1): not covered
      - lib/account.js references account_id (line 1): covered by `lib/account.js`: excluded by decision 2
      - lib/exports.js references account_id (lines 1, 4): not covered
      A file that is not covered holds or reaches data the approved Intent neither scopes nor excludes by a Decision: report a blocking finding at its path. You cannot change the approved Intent; Kogen refuses a verdict without that finding.
      """
    And the data-stores reviewer's verdict 1 received exactly:
      """
      invalid verdict:
      each data store the approved Intent omits needs a blocking finding at its path; the Intent neither scopes it nor excludes it by a Decision: exports/1.json, exports/2.json, lib/exports.js
      """
    And the data-stores Build printed these lines in order:
      """
      candidate/review_blocked: the reviewer could not resolve a substantive blocker within the approved Intent; edits are left in place
      review: exports/1.json:1: holds account 1's export keyed by account_id; the approved Intent neither scopes nor excludes it by a Decision
      review: exports/2.json:1: holds account 2's export keyed by account_id; the approved Intent neither scopes nor excludes it by a Decision
      review: lib/exports.js:1: writes the export files keyed by account_id; the approved Intent neither scopes nor excludes it by a Decision
      """
    And the data-stores Build added 0 commits

  Scenario: Review of a Build whose approved Intent covers every store approves it, and the Build lands
    When the data-stores Build runs the approved Intent that covers every store, and its reviewer approves
    Then the data-stores Build exited with status 0 with outcome "landed" after 1 review request
    And the first data-stores review request contains:
      """
      # Data stores

      Keys declared under the approved Intent's ## Data stores: account_id
      Files tracked at the Build's start commit that reference a declared key, and the item that covers each:
      - db/memberships.csv references account_id (line 1): covered by `db/memberships.csv`: in scope, observed by `db/memberships.csv`
      - exports/1.json references account_id (line 1): covered by `exports/`: in scope, observed by `exports/`
      - exports/2.json references account_id (line 1): covered by `exports/`: in scope, observed by `exports/`
      - lib/account.js references account_id (line 1): covered by `lib/account.js`: excluded by decision 2
      - lib/exports.js references account_id (lines 1, 4): covered by `lib/exports.js`: excluded by decision 3
      A file that is not covered holds or reaches data the approved Intent neither scopes nor excludes by a Decision: report a blocking finding at its path. You cannot change the approved Intent; Kogen refuses a verdict without that finding.
      """
    And the data-stores Build printed these lines in order:
      """
      review: approved
      """
    And the data-stores Build added 1 commit
