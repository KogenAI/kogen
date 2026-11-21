Feature: The release script docs list and the archive mode observer list agree
  This feature checks that the Go tests in cli/package_docs_list_test.go compare the docs copied by packaging/package.sh with SHIPPED_DOCS of the archive mode observer. Each scenario runs those tests against a scratch tree, in a copy of the real script, observer and docs, that has one fault. It needs no model and no network.

  Scenario: The real tree lists the same docs on both sides
    Given package-docs-list-matches-observer: a scratch tree holds the real release script, observer and docs
    Then package-docs-list-matches-observer: the new docs list tests pass on the scratch tree

  Scenario: The same docs in another order with duplicates still agree
    Given package-docs-list-matches-observer: a scratch tree holds the real release script, observer and docs
    And package-docs-list-matches-observer: the scratch lists are reversed and repeat their first name
    Then package-docs-list-matches-observer: the new docs list tests pass on the scratch tree

  Scenario: A renamed observer entry is rejected on both sides
    Given package-docs-list-matches-observer: a scratch tree holds the real release script, observer and docs
    And package-docs-list-matches-observer: the scratch observer renames "providers.md" to "provider.md"
    Then package-docs-list-matches-observer: the new docs list tests reject the scratch tree with "providers.md: observer lacks it"
    And package-docs-list-matches-observer: the new docs list tests reject the scratch tree with "provider.md: script lacks it"

  Scenario: The drift of 21 November is rejected
    Given package-docs-list-matches-observer: a scratch tree holds the real release script, observer and docs
    And package-docs-list-matches-observer: the scratch observer drops "providers.md"
    Then package-docs-list-matches-observer: the new docs list tests reject the scratch tree with "providers.md: observer lacks it"

  Scenario: An observer doc the script does not copy is rejected
    Given package-docs-list-matches-observer: a scratch tree holds the real release script, observer and docs
    And package-docs-list-matches-observer: the scratch observer adds "legacy.md"
    Then package-docs-list-matches-observer: the new docs list tests reject the scratch tree with "legacy.md: script lacks it"

  Scenario: A copied doc without a file in the docs folder is rejected
    Given package-docs-list-matches-observer: a scratch tree holds the real release script, observer and docs
    And package-docs-list-matches-observer: the scratch script adds "guide.md" to its docs copy line
    And package-docs-list-matches-observer: the scratch observer adds "guide.md"
    And package-docs-list-matches-observer: the scratch docs folder has no "guide.md"
    Then package-docs-list-matches-observer: the new docs list tests reject the scratch tree with "guide.md: docs folder has no such file"

  Scenario: A script without a docs copy line is rejected
    Given package-docs-list-matches-observer: a scratch tree holds the real release script, observer and docs
    And package-docs-list-matches-observer: the scratch script loses its docs copy line
    Then package-docs-list-matches-observer: the new docs list tests reject the scratch tree with "no docs copy line"

  Scenario: A script with two docs copy lines is rejected
    Given package-docs-list-matches-observer: a scratch tree holds the real release script, observer and docs
    And package-docs-list-matches-observer: the scratch script gets a second docs copy line
    Then package-docs-list-matches-observer: the new docs list tests reject the scratch tree with "2 docs copy lines"

  Scenario: An observer without a SHIPPED_DOCS tuple is rejected
    Given package-docs-list-matches-observer: a scratch tree holds the real release script, observer and docs
    And package-docs-list-matches-observer: the scratch observer loses its SHIPPED_DOCS tuple
    Then package-docs-list-matches-observer: the new docs list tests reject the scratch tree with "no SHIPPED_DOCS tuple"

  Scenario: A script and an observer that both lack their list are rejected
    Given package-docs-list-matches-observer: a scratch tree holds the real release script, observer and docs
    And package-docs-list-matches-observer: the scratch script loses its docs copy line
    And package-docs-list-matches-observer: the scratch observer loses its SHIPPED_DOCS tuple
    Then package-docs-list-matches-observer: the new docs list tests reject the scratch tree with "no docs copy line"
    And package-docs-list-matches-observer: the new docs list tests reject the scratch tree with "no SHIPPED_DOCS tuple"
