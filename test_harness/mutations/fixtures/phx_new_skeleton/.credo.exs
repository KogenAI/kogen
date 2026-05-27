%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "src/", "web/", "apps/*/lib", "apps/*/src", "apps/*/web"],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/"]
      },
      strict: true,
      checks: %{
        enabled: [
          {OptimumCredo.Check.Readability.ImportOrder,
           [excluded: [~r"/channel_case\.ex$"]]}
        ]
      }
    }
  ]
}
