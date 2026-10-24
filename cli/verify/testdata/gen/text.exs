# Writes cli/verify/testdata/golden/text.json: the bounded texts of Kogen.Tools.cut/1,
# Kogen.Checks.excerpt/1, Kogen.Checks.tail/2, Kogen.Run.cap/1 and OptionParser.split/1
# (the Elixir reference) for fixed inputs.
#
#   cd <repo> && mise exec -- mix run --no-start cli/verify/testdata/gen/text.exs

lines = fn n -> Enum.map_join(1..n, "\n", &"line #{&1}") end

texts =
  [
    "",
    "short",
    "trailing space   \n\n",
    String.duplicate("x", 16_384),
    String.duplicate("x", 16_385),
    String.duplicate("é", 8_192),
    String.duplicate("é", 8_193),
    String.duplicate("é", 11_000),
    String.duplicate("日本語", 6_000),
    "a" <> String.duplicate("é", 9_000),
    "ab" <> String.duplicate("😀", 5_000),
    String.duplicate("ab\n", 9_000),
    lines.(59) <> "\n",
    lines.(60),
    lines.(61),
    lines.(75) <> "\n\n",
    "\n" <> lines.(70),
    "one line only\n"
  ]

cuts = for t <- texts, do: %{"in" => t, "out" => Kogen.Tools.cut(t)}
excerpts = for t <- texts, do: %{"in" => t, "out" => Kogen.Checks.excerpt(t)}

tails =
  for t <- texts, n <- [1, 20, 60] do
    %{"in" => t, "n" => n, "out" => Kogen.Checks.tail(t, n)}
  end

mib = 1_048_576
caps = for t <- [String.duplicate("x", mib), String.duplicate("é", mib), String.duplicate("a", mib + 1) , String.duplicate("日", div(mib, 3) + 10)] do
  out = Kogen.Run.cap(t)
  %{"len" => byte_size(t), "kind" => String.slice(t, 0, 1), "out_len" => byte_size(out), "out_hash" => :crypto.hash(:sha256, out) |> Base.encode16(case: :lower)}
end

splits =
  for l <- [
        "",
        "   ",
        "true",
        "  a   b  ",
        ~s("/usr/bin/true"),
        ~s("./check tool"),
        ~s(LABEL="two words" /usr/bin/true),
        ~s(./check\\ tool),
        ~s('single quoted' "double \\"q\\" \\\\ x" plain\\ word),
        ~s(a"b c"d 'e f'g),
        ~s(""),
        ~s(a "" b),
        ~s('' x),
        ~s(echo "unterminated),
        ~s(echo 'unterminated),
        "trailing\\",
        "tab\tsep\nnl",
        ~s("it's" 'say "hi"'),
        ~s(é "ü ö"),
        "a\\ b\\\\c\\'d"
      ] do
    try do
      %{"in" => l, "out" => OptionParser.split(l)}
    rescue
      e -> %{"in" => l, "error" => Exception.message(e)}
    end
  end

File.write!(
  Path.join(File.cwd!(), "cli/verify/testdata/golden/text.json"),
  JSON.encode!(%{"cut" => cuts, "excerpt" => excerpts, "tail" => tails, "cap" => caps, "split" => splits}) <> "\n"
)

IO.puts("ok")
