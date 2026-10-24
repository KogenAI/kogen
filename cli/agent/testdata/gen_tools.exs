# Generates tools_golden.json: what the Elixir Kogen.Tools returns for a fixed repository and
# a fixed list of calls. The Go tests replay the same files and calls and compare.
#
#   cd <repo root> && mise exec -- mix run --no-start cli/agent/testdata/gen_tools.exs cli/agent/testdata/tools_golden.json
#
[out] = System.argv()

defmodule Gen do
  def chunk(type, data),
    do: <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>

  @sig <<137, 80, 78, 71, 13, 10, 26, 10>>
  def ihdr(w, h, enc \\ <<8, 2, 0, 0, 0>>), do: chunk("IHDR", <<w::32, h::32, enc::binary>>)

  def png(w, h, raw, extra \\ "", enc \\ <<8, 2, 0, 0, 0>>),
    do: @sig <> ihdr(w, h, enc) <> extra <> chunk("IDAT", :zlib.compress(raw)) <> chunk("IEND", "")

  def raw_png(chunks), do: @sig <> Enum.join(chunks)
  def rows(w, h, filter \\ 0), do: :binary.copy(<<filter>> <> :binary.copy(<<0>>, 3 * w), h)
end


good = :zlib.compress(<<0, 1, 2, 3>>)
<<good_cmf, good_flg, good_rest::binary>> = good

# A zlib header with this CMF and FLG (high bits; FCHECK is filled in).
zheader = fn cmf, flg ->
  fcheck = rem(31 - rem(cmf * 256 + flg, 31), 31)
  <<cmf, flg + fcheck>>
end

images = [
  {"img/valid.png", Gen.png(1, 1, <<0, 255, 0, 0>>)},
  {"img/text.png", Gen.png(1, 1, <<0, 255, 0, 0>>, Gen.chunk("tEXt", "padding\0" <> String.duplicate("x", 30_000)))},
  {"img/signature.png", "not png"},
  {"img/truncated.png", binary_part(Gen.png(1, 1, <<0, 1, 2, 3>>), 0, 40)},
  {"img/crc.png", (fn v -> binary_part(v, 0, byte_size(v) - 1) <> <<0>> end).(Gen.png(1, 1, <<0, 1, 2, 3>>))},
  {"img/trailing.png", Gen.png(1, 1, <<0, 1, 2, 3>>) <> "junk"},
  {"img/compressed_trailing.png", Gen.raw_png([Gen.ihdr(1, 1), Gen.chunk("IDAT", good <> "junk"), Gen.chunk("IEND", "")])},
  {"img/animation.png", Gen.png(1, 1, <<0, 1, 2, 3>>, Gen.chunk("acTL", <<1::32, 0::32>>))},
  {"img/duplicate_palette.png", Gen.png(1, 1, <<0, 1, 2, 3>>, Gen.chunk("PLTE", <<1, 2, 3>>) <> Gen.chunk("PLTE", <<4, 5, 6>>))},
  {"img/palette.png", Gen.png(1, 1, <<0, 1, 2, 3>>, Gen.chunk("PLTE", <<1, 2, 3>>))},
  {"img/palette_size.png", Gen.png(1, 1, <<0, 1, 2, 3>>, Gen.chunk("PLTE", <<1, 2, 3, 4>>))},
  {"img/palette_late.png", Gen.raw_png([Gen.ihdr(1, 1), Gen.chunk("IDAT", good), Gen.chunk("PLTE", <<1, 2, 3>>), Gen.chunk("IEND", "")])},
  {"img/rgba.png", Gen.png(1, 1, <<0, 1, 2, 3>>, "", <<8, 6, 0, 0, 0>>)},
  {"img/interlaced.png", Gen.png(1, 1, <<0, 1, 2, 3>>, "", <<8, 2, 0, 0, 1>>)},
  {"img/depth16.png", Gen.png(1, 1, <<0, 1, 2, 3>>, "", <<16, 2, 0, 0, 0>>)},
  {"img/filter5.png", Gen.png(1, 1, <<5, 1, 2, 3>>)},
  {"img/filter4.png", Gen.png(1, 1, <<4, 1, 2, 3>>)},
  {"img/short.png", Gen.png(1, 1, <<0, 1, 2>>)},
  {"img/long.png", Gen.png(1, 1, <<0, 1, 2, 3, 4>>)},
  {"img/bomb.png", Gen.png(1, 1, String.duplicate(<<0>>, 1_000_000))},
  {"img/zero.png", Gen.png(0, 1, <<0>>)},
  {"img/wide.png", Gen.png(2049, 1, <<0>>)},
  {"img/tall.png", Gen.png(1, 2049, <<0>>)},
  {"img/w2048.png", Gen.png(2048, 1, Gen.rows(2048, 1))},
  {"img/w2047.png", Gen.png(2047, 1, Gen.rows(2047, 1))},
  {"img/h3.png", Gen.png(2, 3, Gen.rows(2, 3, 2))},
  {"img/empty.png", ""},
  {"img/garbage_idat.png", Gen.raw_png([Gen.ihdr(1, 1), Gen.chunk("IDAT", "garbage-not-zlib"), Gen.chunk("IEND", "")])},
  {"img/empty_idat.png", Gen.raw_png([Gen.ihdr(1, 1), Gen.chunk("IDAT", ""), Gen.chunk("IEND", "")])},
  {"img/truncated_zlib.png", Gen.raw_png([Gen.ihdr(1, 1), Gen.chunk("IDAT", binary_part(good, 0, byte_size(good) - 3)), Gen.chunk("IEND", "")])},
  {"img/gzip.png", Gen.raw_png([Gen.ihdr(1, 1), Gen.chunk("IDAT", :zlib.gzip(<<0, 1, 2, 3>>)), Gen.chunk("IEND", "")])},
  {"img/two_streams.png", Gen.raw_png([Gen.ihdr(1, 1), Gen.chunk("IDAT", good <> good), Gen.chunk("IEND", "")])},
  {"img/split_idat.png", Gen.raw_png([Gen.ihdr(1, 1), Gen.chunk("IDAT", binary_part(good, 0, 4)), Gen.chunk("IDAT", binary_part(good, 4, byte_size(good) - 4)), Gen.chunk("IEND", "")])},
  {"img/critical.png", Gen.png(1, 1, <<0, 1, 2, 3>>, Gen.chunk("ABCD", "x"))},
  {"img/ancillary_after.png", Gen.raw_png([Gen.ihdr(1, 1), Gen.chunk("IDAT", good), Gen.chunk("tEXt", "a\0b"), Gen.chunk("IEND", "")])},
  {"img/idat_after_ancillary.png", Gen.raw_png([Gen.ihdr(1, 1), Gen.chunk("IDAT", good), Gen.chunk("tEXt", "a\0b"), Gen.chunk("IDAT", ""), Gen.chunk("IEND", "")])},
  {"img/bad_type.png", Gen.png(1, 1, <<0, 1, 2, 3>>, Gen.chunk("ab_d", "x"))},
  {"img/reserved_bit.png", Gen.png(1, 1, <<0, 1, 2, 3>>, Gen.chunk("abcd", "x"))},
  {"img/ihdr_length.png", Gen.raw_png([Gen.chunk("IHDR", <<1::32, 1::32, 8, 2, 0, 0>>), Gen.chunk("IDAT", good), Gen.chunk("IEND", "")])},
  {"img/two_ihdr.png", Gen.raw_png([Gen.ihdr(1, 1), Gen.ihdr(1, 1), Gen.chunk("IDAT", good), Gen.chunk("IEND", "")])},
  {"img/no_ihdr.png", Gen.raw_png([Gen.chunk("IDAT", good), Gen.chunk("IEND", "")])},
  {"img/no_iend.png", Gen.raw_png([Gen.ihdr(1, 1), Gen.chunk("IDAT", good)])},
  {"img/iend_data.png", Gen.raw_png([Gen.ihdr(1, 1), Gen.chunk("IDAT", good), Gen.chunk("IEND", "x")])},
  {"img/no_idat.png", Gen.raw_png([Gen.ihdr(1, 1), Gen.chunk("IEND", "")])},
  {"img/fdat.png", Gen.raw_png([Gen.ihdr(1, 1), Gen.chunk("fdAT", "x"), Gen.chunk("IDAT", good), Gen.chunk("IEND", "")])},
  {"img/unicode-é.png", Gen.png(1, 1, <<0, 9, 8, 7>>)},
  {"img/window32k.png", Gen.raw_png([Gen.ihdr(1, 1), Gen.chunk("IDAT", zheader.(0x88, 0x80) <> good_rest), Gen.chunk("IEND", "")])},
  {"img/window4k.png", Gen.raw_png([Gen.ihdr(1, 1), Gen.chunk("IDAT", zheader.(0x38, 0x80) <> good_rest), Gen.chunk("IEND", "")])},
  {"img/preset_dictionary.png", Gen.raw_png([Gen.ihdr(1, 1), Gen.chunk("IDAT", zheader.(0x78, 0x20) <> <<1, 2, 3, 4>> <> good_rest), Gen.chunk("IEND", "")])},
  {"img/bad_fcheck.png", Gen.raw_png([Gen.ihdr(1, 1), Gen.chunk("IDAT", <<good_cmf, good_flg + 1>> <> good_rest), Gen.chunk("IEND", "")])},
  {"img/bad_adler.png", Gen.raw_png([Gen.ihdr(1, 1), Gen.chunk("IDAT", binary_part(good, 0, byte_size(good) - 1) <> <<0>>), Gen.chunk("IEND", "")])},
  {"img/method9.png", Gen.raw_png([Gen.ihdr(1, 1), Gen.chunk("IDAT", zheader.(0x79, 0x80) <> good_rest), Gen.chunk("IEND", "")])}
]

files =
  [
    {"a.txt", "one\ntwo\nthree\n"},
    {"empty.txt", ""},
    {"nonl.txt", "a\nb"},
    {"blank.txt", "\n\n"},
    {"crlf.txt", "x\r\ny\r\n"},
    {"tab.txt", "col1\tcol2\n  indented\n"},
    {"many.txt", Enum.map_join(1..120, "", &"line #{&1}\n")},
    {".gitignore", "*.log\nbuild/\n"},
    {"dir/sub.txt", "needle in sub\nsecond line\n"},
    {"dir/é.txt", "héllo needle\n"},
    {"dir/deep/x.txt", "deep needle\n"},
    {"dir/Dash-file.txt", "-needle at start\n"},
    {"src/main.go", "package main\n\nfunc main() {}\n"},
    {"bin.dat", "bin\0needle\0"},
    {"untracked.txt", "needle in untracked\n"},
    {"ignored.log", "needle in ignored\n"},
    {"build/out.txt", "needle in build\n"},
    {"empty-dir/.keep", ""}
  ] ++ images

spec_files =
  Enum.map(files, fn {path, bytes} ->
    if String.valid?(bytes) and byte_size(bytes) < 5000 and not String.contains?(bytes, "\0"),
      do: %{"path" => path, "content" => bytes},
      else: %{"path" => path, "b64" => Base.encode64(bytes)}
  end) ++
    [%{"path" => "link.txt", "link" => "a.txt"}, %{"path" => "broken-link", "link" => "no-such-target"}, %{"path" => "img-link.png", "link" => "img/valid.png"}]

untracked = ["untracked.txt", "ignored.log", "build/out.txt", "img/text.png", "img/long.png"]

tracked =
  (Enum.map(spec_files, & &1["path"]) -- untracked) -- ["ignored.log", "build/out.txt"]

# Calls: {tool, arguments text}
r = fn args -> {"read_file", args} end

calls =
  [
    r.(~s({"path":"a.txt"})),
    r.(~s({"path":"a.txt","start_line":2})),
    r.(~s({"path":"a.txt","end_line":2})),
    r.(~s({"path":"a.txt","start_line":2,"end_line":2})),
    r.(~s({"path":"a.txt","start_line":3,"end_line":1})),
    r.(~s({"path":"a.txt","start_line":0})),
    r.(~s({"path":"a.txt","start_line":-4})),
    r.(~s({"path":"a.txt","start_line":"2"})),
    r.(~s({"path":"a.txt","start_line":2.0})),
    r.(~s({"path":"a.txt","start_line":1e0,"end_line":2})),
    r.(~s({"path":"a.txt","end_line":2.5})),
    r.(~s({"path":"a.txt","start_line":99})),
    r.(~s({"path":"a.txt","end_line":0})),
    r.(~s({"path":"a.txt","end_line":-1})),
    r.(~s({"path":"a.txt","start_line":123456789012345678901234567890})),
    r.(~s({"path":"a.txt","end_line":123456789012345678901234567890})),
    r.(~s({"path":"a.txt","start_line":-123456789012345678901234567890})),
    r.(~s({"path":"a.txt","start_line":null,"end_line":null})),
    r.(~s({"path":"many.txt","start_line":118})),
    r.(~s({"path":"many.txt","start_line":10,"end_line":12})),
    r.(~s({"path":"empty.txt"})),
    r.(~s({"path":"nonl.txt"})),
    r.(~s({"path":"blank.txt"})),
    r.(~s({"path":"crlf.txt"})),
    r.(~s({"path":"tab.txt"})),
    r.(~s({"path":"dir/é.txt"})),
    r.(~s({"path":"dir"})),
    r.(~s({"path":""})),
    r.(~s({"path":"."})),
    r.(~s({"path":"missing.txt"})),
    r.(~s({"path":"a.txt/b"})),
    r.(~s({"path":"link.txt"})),
    r.(~s({"path":"broken-link"})),
    r.(~s({"path":"<ROOT>/a.txt"})),
    r.(~s({"path":"dir/../a.txt"})),
    r.(~s({"path":"./a.txt"})),
    r.(~s({"path":"//a.txt"})),
    r.(~s({"path":"../kogen-agent-definitely-missing-xyz"})),
    r.(~s({"path":"dir/missing/é.txt"})),
    r.(~s({"path":5})),
    r.(~s({"path":null})),
    r.(~s({"start_line":1})),
    r.(~s({"path":"a.txt","path":"empty.txt"})),
    r.("{}"),
    r.("not json"),
    r.("[1]"),
    r.(""),
    r.("null"),
    r.("\"a.txt\""),
    r.(~s({"path":"a.txt"} trailing)),
    r.(~s({"path":"a.txt"}  )),
    r.(~s(  {"path":"a.txt"})),
    r.(~s({"path":"a.txt",})),
    r.(~s({"path":"\\u00e9.txt"})),
    r.(~s({"path":"dir/\\u00e9.txt"})),
    r.(~s({"path":"\\ud800"})),
    r.(~s({"path":"a.txt","start_line":01})),
    r.(~s({"path":"a.txt","start_line":-0})),
    r.(~s({"path":"a.txt","start_line":1E1})),
    r.(~s({"path":"a\\u0000b"})),
    r.(~s({"path":"~/kogen-agent-missing-xyz"})),
    r.(~s({"path":"~"})),
    r.(~s({"path":"~x/y"})),
    r.(~s({"path":"a.txt","start_line":1e999})),
    r.(~s({"path":"\\ud83d\\ude00"})),
    r.(~s({"path":"\\ud83dx"})),
    r.(~s({"path":"\\udc00"})),
    r.(~s({"path":"\\ud83d\\u0041"})),
    r.(~s({"path":"a.txt","start_line":2}\n)),
    r.("\uFEFF{\"path\":\"a.txt\"}"),
    r.("{\"path\":\"a\tb\"}"),
    r.(~s({"path":"a.txt","start_line":NaN})),
    r.(~s({"path":"a.txt","x":[1,[2,{"y":null}],"z"]})),
    r.(~s({"path":"\\/a.txt"})),
    {"read_file", ~s({"path":"a.txt"})},
    # write_file; protected: a.txt
    {"write_file", ~s({"path":"new/deep/f.txt","content":"hi"})},
    r.(~s({"path":"new/deep/f.txt"})),
    {"write_file", ~s({"path":"new/deep/f.txt","content":"héllo\\nwörld\\n"})},
    r.(~s({"path":"new/deep/f.txt"})),
    {"write_file", ~s({"path":"a.txt","content":"x"})},
    {"write_file", ~s({"path":"./a.txt","content":"x"})},
    {"write_file", ~s({"path":"dir/../a.txt","content":"x"})},
    {"write_file", ~s({"path":"<ROOT>/a.txt","content":"x"})},
    r.(~s({"path":"a.txt"})),
    {"write_file", ~s({"path":"dir","content":"x"})},
    {"write_file", ~s({"path":"link.txt/x","content":"x"})},
    {"write_file", ~s({"path":"empty.txt/x/y","content":"x"})},
    {"write_file", ~s({"path":"","content":"x"})},
    {"write_file", ~s({"path":"w.txt","content":42})},
    {"write_file", ~s({"path":"w.txt"})},
    {"write_file", ~s({"content":"x"})},
    {"write_file", ~s({"path":5,"content":"x"})},
    {"write_file", ~s({"path":"empty-new.txt","content":""})},
    r.(~s({"path":"empty-new.txt"})),
    {"write_file", ~s({"path":"a.txt/..","content":"x"})},
    {"write_file", "not json"},
    {"write_file", ~s({"path":"link.txt","content":"through link"})},
    r.(~s({"path":"a.txt"})),
    {"write_file", ~s({"path":"broken-link","content":"through broken link"})},
    # list_files
    {"list_files", ~s({})},
    {"list_files", ~s({"path":"dir"})},
    {"list_files", ~s({"path":"dir/"})},
    {"list_files", ~s({"path":"."})},
    {"list_files", ~s({"path":""})},
    {"list_files", ~s({"path":"missing"})},
    {"list_files", ~s({"path":"empty-dir"})},
    {"list_files", ~s({"path":"../x"})},
    {"list_files", ~s({"path":"<ROOT>/dir"})},
    {"list_files", ~s({"path":"/tmp"})},
    {"list_files", ~s({"path":5})},
    {"list_files", ~s({"path":"build"})},
    {"list_files", ~s({"path":"dir/../src"})},
    {"list_files", ~s({"path":"new"})},
    {"list_files", "not json"},
    {"list_files", ~s({"path":"a\\u0000b"})},
    {"write_file", ~s({"path":"a\\u0000b","content":"x"})},
    {"write_file", ~s({"path":"d\\u0000/f","content":"x"})},
    {"search_text", ~s({"pattern":"a\\u0000b"})},
    {"search_text", ~s({"pattern":"a","path":"a\\u0000b"})},
    {"view_image", ~s({"path":"a\\u0000b"})},
    {"view_image", ~s({"path":"~/kogen-missing.png"})},
    # search_text
    {"search_text", ~s({"pattern":"needle"})},
    {"search_text", ~s({"pattern":"needle","path":"dir"})},
    {"search_text", ~s({"pattern":"needle","path":"dir/deep/x.txt"})},
    {"search_text", ~s({"pattern":"zzz-no-such"})},
    {"search_text", ~s({"pattern":"zzz-no-such","path":"missing"})},
    {"search_text", ~s({"pattern":"("})},
    {"search_text", ~s({"pattern":"[a"})},
    {"search_text", ~s({"pattern":"-needle"})},
    {"search_text", ~s({"pattern":"^h.llo"})},
    {"search_text", ~s({"pattern":"é"})},
    {"search_text", ~s({"pattern":""})},
    {"search_text", ~s({"pattern":"one|two"})},
    {"search_text", ~s({"pattern":"hi","path":"new"})},
    {"search_text", ~s({"pattern":"needle","path":"../x"})},
    {"search_text", ~s({"path":"dir"})},
    {"search_text", ~s({"pattern":5})},
    {"search_text", ~s({"pattern":"needle","path":5})},
    {"search_text", ~s({"pattern":"main","path":"src"})},
    {"search_text", ~s({"pattern":"\\\\bfunc\\\\b"})},
    {"search_text", ~s({"pattern":"line 1[0-9]$","path":"many.txt"})},
    # unknown tools
    {"shell", ~s({"command":"true"})},
    {"finish", ~s({"summary":"done"})},
    {"bogus", ~s({})},
    {"", ~s({})}
  ] ++
    Enum.flat_map(images, fn {path, _} -> [{"view_image", ~s({"path":#{inspect(path)}})}] end) ++
    [
      {"view_image", ~s({"path":"img-link.png"})},
      {"view_image", ~s({"path":"<ROOT>/img/valid.png"})},
      {"view_image", ~s({"path":"img/../img/valid.png"})},
      {"view_image", ~s({"path":"img"})},
      {"view_image", ~s({"path":""})},
      {"view_image", ~s({"path":"."})},
      {"view_image", ~s({"path":"absent.png"})},
      {"view_image", ~s({"path":"a.txt/b"})},
      {"view_image", ~s({"path":"broken-link"})},
      {"view_image", ~s({"path":42})},
      {"view_image", ~s({"path":null})},
      {"view_image", ~s({})},
      {"view_image", "not json"},
      {"view_image", ~s({"path":"#{String.duplicate("x", 600)}"})},
      {"view_image", ~s({"path":"#{String.duplicate("é", 300)}.png"})},
      {"view_image", ~s({"path":"#{String.duplicate("y", 300)}/#{String.duplicate("z", 300)}"})},
      {"view_image", ~s({"path":"a.txt"})},
      {"view_image", ~s({"path":"bin.dat"})},
      {"view_image", ~s({"path":"empty.txt"})},
      {"view_image", ~s({"path":"quote\\"back\\\\slash\\n.png"})}
    ]

# ---- run ----
System.put_env("GIT_CONFIG_GLOBAL", "/dev/null")
System.put_env("GIT_CONFIG_NOSYSTEM", "1")
base = Path.join(System.tmp_dir!(), "kogen-agent-golden-#{System.unique_integer([:positive])}")
File.mkdir_p!(base)
root = base |> Path.join("repo")
File.mkdir_p!(root)
# real path (macOS /var -> /private/var)
{real, 0} = System.cmd("pwd", ["-P"], cd: root)
real = String.trim(real)
root = real

git = fn args ->
  {o, s} = System.cmd("git", ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null" | args], cd: root, stderr_to_stdout: true, env: [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}])
  if s != 0, do: raise("git #{inspect(args)}: #{o}")
  o
end

git.(["init", "-q"])

for f <- spec_files do
  dest = Path.join(root, f["path"])
  File.mkdir_p!(Path.dirname(dest))

  cond do
    f["link"] -> File.ln_s!(f["link"], dest)
    f["b64"] -> File.write!(dest, Base.decode64!(f["b64"]))
    true -> File.write!(dest, f["content"])
  end
end

git.(["add", "--" | tracked])
git.(["commit", "-q", "-m", "init"])

ctx = %{root: root, tools: ~w(read_file write_file list_files search_text view_image), protected: ["a.txt"]}

scrub = fn text ->
  text |> String.replace(root, "<ROOT>") |> String.replace(Path.dirname(root), "<BASE>")
end

results =
  for {name, arguments} <- calls do
    arguments = String.replace(arguments, "<ROOT>", root)

    args =
      case JSON.decode(arguments) do
        {:ok, args} when is_map(args) -> args
        _ -> %{"__invalid__" => true}
      end

    result = Kogen.Tools.run(name, args, ctx)

    result =
      case result do
        list when is_list(list) -> Enum.map(list, fn m -> Map.new(m, fn {k, v} -> {k, scrub.(v)} end) end)
        text -> scrub.(text)
      end

    %{"name" => name, "arguments" => String.replace(arguments, root, "<ROOT>"), "result" => result}
  end

spec = %{
  "files" => spec_files,
  "tracked" => tracked,
  "tools" => ctx.tools,
  "protected" => ctx.protected,
  "calls" => results
}

line = fn m -> JSON.encode!(m) end

body =
  ~s({\n"files": [\n) <>
    Enum.map_join(spec_files, ",\n", line) <>
    ~s(\n],\n"tracked": #{JSON.encode!(tracked)},\n"tools": #{JSON.encode!(ctx.tools)},\n"protected": #{JSON.encode!(ctx.protected)},\n"calls": [\n) <>
    Enum.map_join(results, ",\n", line) <> "\n]\n}\n"

_ = spec
File.write!(out, body)
File.rm_rf!(base)
IO.puts("wrote #{out}: #{length(results)} calls")
