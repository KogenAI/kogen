Feature: Review material on demand (review_material config lever)

  Scenario: With the key absent an overflowing candidate keeps today's opening request and refuses unread parts
    When the krevod observation "default-overflow" runs
    Then the krevod default opening is unchanged and the unread approval was refused

  Scenario: With on_demand the opening request carries the manifest and no part body, and an approval with no part read is accepted
    When the krevod observation "on-demand-none" runs
    Then the krevod opening carries the manifest and no part body
    And the krevod approval with no part read was accepted

  Scenario: With on_demand an approval after reading one part is accepted
    When the krevod observation "on-demand-one" runs
    Then the krevod opening carries the manifest and no part body
    And the krevod approval after one part read was accepted

  Scenario: Reading a part by id and a file by line range return the same bytes as in parts mode
    When the krevod observation "reads" runs
    Then the krevod part and line-range reads equal the default mode bytes

  Scenario: With on_demand and a candidate that fits inline the request is identical to parts
    When the krevod observation "inline" runs
    Then the krevod on_demand request equals the parts request when the source fits

  Scenario: An invalid review_material value is refused at config load with the key named
    When the krevod observation "config" runs
    Then the krevod config refuses invalid review_material values naming the key

  Scenario: The key is documented as experimental and off by default
    Then the krevod configuration documentation presents review_material as experimental and off by default
