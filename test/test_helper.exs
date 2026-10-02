_ = Application.ensure_all_started(:credo)
ExUnit.start(formatters: [ExUnit.CLIFormatter, Kogen.Testkit.BudgetFormatter])
