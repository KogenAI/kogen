Feature: Run records carry the fields research needs to measure caching and context
  Scenario: A fake-provider Build with one round, one review and a reset records the six fields
    When the k9 Build plays one round, one review and a reset against the fake provider
    Then the k9 Build run record carries the six fields

  Scenario: A Shape run records its attempt number and request size on every request
    When the k9 Shape plays a request audit and a refused first submission against the fake provider
    Then the k9 Shape run records carry shape_attempt and request_bytes on every request
