cols = :io.columns()
ansi = IO.ANSI.enabled?()
{:ok, opts} = :io.getopts(:standard_io) |> then(&{:ok, &1})
IO.write(:stderr, "columns=#{inspect(cols)} ansi_enabled=#{ansi} terminal_opt=#{inspect(Keyword.get(opts, :terminal))}\n")
if match?({:ok, _}, cols) do
  for s <- 1..3 do
    IO.write("\r\e[2K▸ Developer turn 1…  #{s}s"); Process.sleep(300)
  end
  IO.write("\r\e[2K  Developer turn 1        3s\n")
else
  IO.write("  Developer turn 1        3s\n")
end
