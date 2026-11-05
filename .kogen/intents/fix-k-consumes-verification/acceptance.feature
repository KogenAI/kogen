Feature: The k-consumes-verification review finding does not reproduce in kogen
  The finding names kogen-verification's consumes/kogen-loop/sys_test.go and the
  tests TestCommand, TestInterruptAndError and TestTmpPath. None of them is part
  of this kogen checkout; they live in the kogen-verification version kogen pins,
  so there is nothing to change here.

  Scenario: None of the named tests exists in kogen's Go tests
    Then fix-k-consumes-verification: no Go test file under "cli" defines "TestCommand"
    And fix-k-consumes-verification: no Go test file under "cli" defines "TestInterruptAndError"
    And fix-k-consumes-verification: no Go test file under "cli" defines "TestTmpPath"

  Scenario: None of the cited expressions is in kogen's Go code
    Then fix-k-consumes-verification: no Go file under "cli" contains 'errors.Is(fmt.Errorf("wrap: %w", sys.ErrTimeoutObservation), sys.ErrTimeoutObservation)'
    And fix-k-consumes-verification: no Go file under "cli" contains 'filepath.Base(p) == ""'
    And fix-k-consumes-verification: no Go file under "cli" contains '"extra:"+dir'

  Scenario: No README in kogen has the finding's assertion column
    Then fix-k-consumes-verification: no Markdown file in the checkout has a table column headed "Direct assertions"

  Scenario: The finding lives in the pinned kogen-verification module
    Given fix-k-consumes-verification: "cli/go.mod" requires "github.com/KogenAI/kogen-verification" at "v0.0.0-20261105151659-f5babef00998"
    Then fix-k-consumes-verification: in the module "github.com/KogenAI/kogen-verification" that "cli" resolves, "consumes/kogen-loop/sys_test.go" contains 'errors.Is(fmt.Errorf("wrap: %w", sys.ErrTimeoutObservation), sys.ErrTimeoutObservation)'
    And fix-k-consumes-verification: in the module "github.com/KogenAI/kogen-verification" that "cli" resolves, "consumes/kogen-loop/sys_test.go" contains 'filepath.Base(p) == ""'
    And fix-k-consumes-verification: in the module "github.com/KogenAI/kogen-verification" that "cli" resolves, "consumes/kogen-loop/sys_test.go" contains '"extra:"+dir'
    And fix-k-consumes-verification: in the module "github.com/KogenAI/kogen-verification" that "cli" resolves, "consumes/kogen-loop/sys_test.go" does not contain "RefuseForeignKill"
    And fix-k-consumes-verification: in the module "github.com/KogenAI/kogen-verification" that "cli" resolves, "consumes/kogen-loop/sys_test.go" does not contain "Context:"
    And fix-k-consumes-verification: in the module "github.com/KogenAI/kogen-verification" that "cli" resolves, "consumes/README.md" contains "RefuseForeignKill"
