Feature: Shape Go probes reuse caller caches
  Scenario: Explicit caches survive isolation without a caller secret
    When a Go cache regression probe builds a minimal Go package with caller secret "caller-only-sentinel"
    Then the Go cache probe reports exactly:
      """
      build-cache=same
      module-cache=same
      secret=absent
      home=private
      build-cache=populated
      """
