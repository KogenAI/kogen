Feature: Finish the commit of a verified, approved Build whose only failure was the commit step
  The installed kogen runs a fixture Build with the scripted local provider: pass 1 is green, review 1
  approves, and the signed git commit fails because the configured signing program fails. The caller
  then fixes the signing setup and runs the existing `kogen intent resume <build-id>`.

  Scenario: After the signing program is fixed, resume commits exactly the verified and reviewed candidate
    When commit-fail-resume runs a verified, approved fixture Build whose signed commit fails, then resumes it in mode "fixed"
    Then commit-fail-resume sees the Build stopped as environment/commit_failed with HEAD unchanged, the verified change uncommitted and the resume command named
    And commit-fail-resume sees inspect offer the resume with the commit failure as the only blocker
    And commit-fail-resume sees the resume make one signed commit of exactly the reviewed tree on the start HEAD, with no builder round, review, check or provider request

  Scenario: A resume after the verified tree was edited is still refused and changes nothing
    When commit-fail-resume runs a verified, approved fixture Build whose signed commit fails, then resumes it in mode "edited"
    Then commit-fail-resume sees the Build stopped as environment/commit_failed with HEAD unchanged, the verified change uncommitted and the resume command named
    And commit-fail-resume sees inspect offer the resume with the commit failure as the only blocker
    And commit-fail-resume sees the resume refused naming the edited path, with no new run, commit or change
