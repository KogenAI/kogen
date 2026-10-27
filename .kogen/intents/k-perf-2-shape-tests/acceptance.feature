Feature: kogen/shape tests are fast and keep their coverage

  Scenario: Test count and names are unchanged
    When I list the Go tests of the shape package
    Then there are 222 tests whose sorted names hash to "08e51876f8a3812da38ec3e97e7b0e38"

  Scenario: No timeout is added and no test is skipped or tagged away
    Given the shape test sources and the project configuration
    Then the go-test check command is exactly "(cd cli && go test -race -count=1 ./...)"
    And the shape test sources contain exactly 2 t.Skip calls and no build tags

  Scenario: The shape package runs in at most half of the 131 to 140 seconds it took before
    When I run the shape tests with the race detector and GOMAXPROCS 2 once
    Then the package passes with every listed test run and passed and none skipped or failed
    And the package elapsed time is at most 65 seconds
