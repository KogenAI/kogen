Feature: Shape probes in Elixir repositories reach the caller's Hex
  A Shape probe uses the Mix toolchain the caller installed, the Hex archive and Hex package cache included,
  while it still receives no caller credential: no secret variable and no hex.config from the caller's Hex home.

  Scenario Outline: A probe compiles a Mix project whose Hex dependency is already fetched (<homes>)
    Given a minimal Mix project whose Hex dependency "kogen_probe_dep" version "1.0.0" is already fetched
    And the caller's Mix and Hex homes are "<homes>", the Hex home holding the cached package, a registry cache and a hex.config with the saved key "hex-config-saved-key"
    And the caller's environment also has HEX_API_KEY set to "hex-api-key-secret"
    And the caller's environment also has KOGEN_PROBE_CALLER_SECRET set to "caller-secret-value"
    When a Shape probe runs in the Mix project:
      """
      set -e
      if ! mix compile > compile.log 2>&1; then cat compile.log; exit 1; fi
      mix run --no-start -e 'IO.puts("answer: #{ProbeFixture.answer()}")'
      hex_home="${HEX_HOME:-$HOME/.hex}"
      echo "hex cache: $(ls "$hex_home/packages/hexpm" 2>&1)"
      if test -e "$hex_home/hex.config"; then echo "hex.config: visible"; else echo "hex.config: absent"; fi
      echo "HEX_API_KEY: ${HEX_API_KEY-unset}"
      echo "KOGEN_PROBE_CALLER_SECRET: ${KOGEN_PROBE_CALLER_SECRET-unset}"
      echo "caller secret values in the environment: $(env | grep -c -e hex-config-saved-key -e hex-api-key-secret -e caller-secret-value)"
      """
    Then the caller's Hex home still holds exactly:
      """
      cache.bin
      hex.config
      packages/hexpm/kogen_probe_dep-1.0.0.tar
      """
    And the Mix probe exits with status 0 and output exactly:
      """
      answer: 42
      hex cache: kogen_probe_dep-1.0.0.tar
      hex.config: absent
      HEX_API_KEY: unset
      KOGEN_PROBE_CALLER_SECRET: unset
      caller secret values in the environment: 0
      """

    Examples:
      | homes                                                  |
      | MIX_HOME and HEX_HOME outside the caller's HOME        |
      | the defaults ~/.mix and ~/.hex under the caller's HOME |
