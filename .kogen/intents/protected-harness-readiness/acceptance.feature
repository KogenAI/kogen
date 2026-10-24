Feature: Expose unexercised protected acceptance
  Readiness remains accounted red, not proof of a skipped harness tail.
  The local Git actor is the fixture's actual seeded HEAD, not Studio history.

  Scenario: An early failure masks history assumptions until they are exercised
    When I inspect protected harness readiness for "history"
    Then the protected harness observations are:
      """
      {
        "first": {
          "scenarios": [{"name":"Masked history","line":2,"status":"failed","unexercised_steps":[{"keyword":"Then ","text":"the historical baseline is readable","line":4},{"keyword":"And ","text":"the final assertion runs","line":5}]}],
          "notice":true,"listed":true,"counted":true
        },
        "source_statuses":[0,0,0],
        "retained":{"executions":0,"same":true,"notice":true},
        "incomplete_record_executions":1,
        "initial_history_executions":0,
        "reached": {
          "scenarios":[{"name":"Masked history","line":2,"status":"failed","unexercised_steps":[{"keyword":"And ","text":"the final assertion runs","line":5}]}],
          "notice":true,"listed":true,"counted":true,"history_failure":true
        },
        "scratch_statuses":[[128,128,128]],
        "corrected": {
          "scenarios":[{"name":"Masked history","line":2,"status":"passed","unexercised_steps":[]}],
          "notice":false,"listed":false,"counted":false
        },
        "no_approval":true,"index_and_head_unchanged":true,"no_provider_calls":true
      }
      """

  Scenario: A failed Before hook leaves Background and scenario steps unexercised
    When I inspect protected harness readiness for "hook"
    Then the protected harness observations are:
      """
      {
        "first": {
          "scenarios":[{"name":"Failed before hook","line":4,"status":"failed","unexercised_steps":[{"keyword":"Given ","text":"background is available","line":3},{"keyword":"Then ","text":"the final assertion runs","line":5}]}],
          "notice":true,"listed":true,"counted":true
        },
        "source_statuses":[0,0,0],
        "retained":{"executions":0,"same":true,"notice":true},
        "incomplete_record_executions":1,
        "hook_failure_retained":true,
        "no_approval":true,"index_and_head_unchanged":true,"no_provider_calls":true
      }
      """

  Scenario: Outline rows keep expanded skipped texts separate from passed rows
    When I inspect protected harness readiness for "outline"
    Then the protected harness observations are:
      """
      {
        "first": {
          "scenarios":[
            {"name":"Case first","line":10,"status":"failed","unexercised_steps":[{"keyword":"Then ","text":"result first is checked","line":6},{"keyword":"And ","text":"final first is checked","line":7}]},
            {"name":"Case second","line":11,"status":"passed","unexercised_steps":[]}
          ],
          "notice":true,"listed":true,"counted":true
        },
        "source_statuses":[0,0,0],
        "retained":{"executions":0,"same":true,"notice":true},
        "incomplete_record_executions":1,
        "no_approval":true,"index_and_head_unchanged":true,"no_provider_calls":true
      }
      """
