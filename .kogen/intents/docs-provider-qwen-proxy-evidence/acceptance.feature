Feature: QwenCloud Build evidence route in the providers guide
  This feature covers the QwenCloud section of docs/providers.md and the Go test that checks that page.

  Scenario: The QwenCloud section says the Build evidence came through the fleet proxy
    When docs-provider-qwen-proxy-evidence: the Go tests of the providers guide are run
    Then docs-provider-qwen-proxy-evidence: the QwenCloud section has one sentence directly after the label line that names the fleet proxy and says the direct public-install Build is still under test, before the setup example
    And docs-provider-qwen-proxy-evidence: the Go tests of the providers guide passed and the Go test file covers the fleet proxy sentence
    And docs-provider-qwen-proxy-evidence: no other line of the page was reworded or removed and no emoji was added
