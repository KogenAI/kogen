Feature: Compact unchanged readiness acknowledgements
  Scenario Outline: Guide a narrow acknowledgement without losing corrections
    When I exercise compact acknowledgement through installed "<operation>"
    Then the compact acknowledgement observations are:
      | observation                      | expected |
      | files minItems                   | 1        |
      | empty submission rejected        | true     |
      | unsafe submission rejected       | true     |
      | candidate readiness executions   | 2        |
      | smallest artifact submitted      | true     |
      | exact complete package retained  | true     |
      | evidence matches complete inputs | true     |
      | no approval                      | true     |
      | prompt contains                  | smallest eligible owned artifact |
      | prompt contains                  | current candidate |
      | prompt contains                  | corrections |
      | prompt contains                  | omitted |
      | prompt contains                  | nonempty |
      | feedback contains                | smallest eligible owned artifact |
      | feedback contains                | current candidate |
      | feedback contains                | corrections |
      | feedback contains                | omitted |
      | feedback contains                | nonempty |
      | obsolete feedback absent         | resubmit the unchanged complete candidate |
      | obsolete feedback absent         | resubmit the unchanged cumulative candidate |

    Examples:
      | operation |
      | shape     |
      | refine    |
