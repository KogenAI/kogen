%{
  configs: [
    %{
      name: "default",
      strict: true,
      parse_timeout: 5000,
      files: %{included: ["lib/", "test/"], excluded: [~r"/_build/", ~r"/deps/"]},
      checks: %{
        enabled: [
          # --- stock Warning (correctness/security)
          {Credo.Check.Warning.UnusedEnumOperation, []},
          {Credo.Check.Warning.UnusedFileOperation, []},
          {Credo.Check.Warning.UnusedKeywordOperation, []},
          {Credo.Check.Warning.UnusedListOperation, []},
          {Credo.Check.Warning.UnusedMapOperation, []},
          {Credo.Check.Warning.UnusedPathOperation, []},
          {Credo.Check.Warning.UnusedRegexOperation, []},
          {Credo.Check.Warning.UnusedStringOperation, []},
          {Credo.Check.Warning.UnusedTupleOperation, []},
          {Credo.Check.Warning.OperationOnSameValues, []},
          {Credo.Check.Warning.OperationWithConstantResult, []},
          {Credo.Check.Warning.BoolOperationOnSameValues, []},
          {Credo.Check.Warning.UnsafeExec, []},
          {Credo.Check.Warning.UnsafeToAtom, []},
          {Credo.Check.Warning.LeakyEnvironment, []},
          {Credo.Check.Warning.MixEnv, []},
          {Credo.Check.Warning.Dbg, []},
          {Credo.Check.Warning.IoInspect, []},
          {Credo.Check.Warning.IExPry, []},
          {Credo.Check.Warning.RaiseInsideRescue, []},
          {Credo.Check.Warning.ExpensiveEmptyEnumCheck, []},
          {Credo.Check.Warning.MapGetUnsafePass, []},
          {Credo.Check.Warning.WrongTestFilename, []},
          {Credo.Check.Warning.ApplicationConfigInModuleAttribute, []},
          {Credo.Check.Warning.SpecWithStruct, []},
          # --- stock Refactor
          {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 12]},
          {Credo.Check.Refactor.Nesting, [max_nesting: 3]},
          {Credo.Check.Refactor.FunctionArity, [max_arity: 6]},
          {Credo.Check.Refactor.RedundantWithClauseResult, []},
          {Credo.Check.Refactor.NegatedConditionsWithElse, []},
          {Credo.Check.Refactor.UnlessWithElse, []},
          {Credo.Check.Refactor.MatchInCondition, []},
          {Credo.Check.Design.TagFIXME, []},
          {Credo.Check.Design.SkipTestWithoutComment, []},
          {Credo.Check.Consistency.ExceptionNames, []},
          # --- custom (prototypes)
          {KogenChecks.Check.ForbiddenCall,
           [
             rules: [
               %{
                 calls: [
                   {File, :cd!},
                   {File, :cd},
                   {System, :put_env},
                   {System, :delete_env},
                   {Application, :put_env}
                 ],
                 message: "Pass ctx.root / ctx.env instead of mutating process-global state.",
                 allow: []
               },
               %{
                 calls: [{Process, :sleep}, {:timer, :sleep}],
                 message: "Wait on a message (assert_receive) or the injected clock.",
                 allow: []
               },
               %{
                 calls: [{System, :cmd}, {Port, :open}, {:os, :cmd}, {System, :shell}],
                 message: "Spawn through the Proc port (own group, wall deadline, TERM->KILL).",
                 allow: ["lib/kogen/proc/", "test/support/testkit/"]
               },
               %{
                 calls: [
                   {System, :get_env},
                   {System, :fetch_env!},
                   {File, :cwd!},
                   {File, :cwd},
                   {DateTime, :utc_now},
                   {System, :os_time}
                 ],
                 message: "Read root/env/clock from ctx.",
                 allow: ["lib/kogen/kernel/", "test/"]
               }
             ]
           ]},
          {KogenChecks.Check.SizeLimits,
           [max_file_lines: 400, max_module_lines: 400, max_function_lines: 40]},
          {KogenChecks.Check.TestModuleShape, [max_tests: 30, serial_allowed: []]},
          {KogenChecks.Check.DomainReach, [also_allowed: [Kogen.Testkit]]},
          {KogenChecks.Check.DomainSize, [max_lines: 3000]},
          {KogenChecks.Check.BroadRescue, []}
        ],
        disabled: []
      }
    }
  ]
}
