defmodule Kogen.ImageTest do
  use ExUnit.Case, async: true
  alias Kogen.{Tools, Shape, WorkingContext, ChatGPT, Image}

  defp chunk(type, data),
    do: <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>

  defp png(w, h, raw, extra \\ "", encoding \\ <<8, 2, 0, 0, 0>>) do
    <<137, 80, 78, 71, 13, 10, 26, 10>> <>
      chunk("IHDR", <<w::32, h::32, encoding::binary>>) <>
      extra <> chunk("IDAT", :zlib.compress(raw)) <> chunk("IEND", "")
  end

  setup do
    root = Kogen.tmp_path("image-unit")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, ctx: %{root: root, tools: ["view_image"], protected: []}}
  end

  test "original bytes stay typed through output, cut, deletion and complete JSON accounting", %{
    root: root,
    ctx: ctx
  } do
    bytes =
      png(1, 1, <<0, 255, 0, 0>>, chunk("tEXt", "padding\0" <> String.duplicate("x", 30_000)))

    path = Path.join(root, "pixels.png")
    File.write!(path, bytes)
    assert [%{"name" => "view_image"}] = Tools.defs(["view_image"])
    result = Tools.run("view_image", %{"path" => "pixels.png"}, ctx)

    assert [
             %{"type" => "input_text", "text" => text},
             %{"type" => "input_image", "image_url" => url}
           ] = result

    assert JSON.decode!(text) == %{
             "version" => 1,
             "path" => "pixels.png",
             "sha256" => WorkingContext.hash(bytes),
             "bytes" => byte_size(bytes),
             "format" => "png",
             "width" => 1,
             "height" => 1,
             "read_candidate" => "UNKNOWN",
             "capture_candidate" => "UNKNOWN",
             "route" => "UNKNOWN",
             "viewport" => "UNKNOWN",
             "fixture_state" => "UNKNOWN"
           }

    assert url == "data:image/png;base64," <> Base.encode64(bytes)
    assert Tools.cut(result) == result
    output = Shape.output(%{"call_id" => "pixels-1"}, result)
    File.rm!(path)

    assert output == %{
             "type" => "function_call_output",
             "call_id" => "pixels-1",
             "output" => result
           }

    body =
      ChatGPT.request_body(
        %{model: "gpt-6.1-sol", effort: "high"},
        "Δ🙂 policy",
        [output],
        Tools.defs(["view_image"])
      )

    assert output in body["input"]
    empty = Map.put(body, "padding", "")
    size = byte_size(JSON.encode!(empty))

    for {n, fits} <- [{524_287, true}, {524_288, true}, {524_289, false}] do
      request = Map.put(empty, "padding", String.duplicate("x", n - size))

      assert WorkingContext.measure(request) == %{
               rendered_bytes: n,
               input_budget_bytes: 524_288,
               output_reserve_tokens: 131_072,
               fits: fits
             }

      if fits,
        do: Image.guard!(request, "shape"),
        else: assert_raise(Kogen.Error, fn -> Image.guard!(request, "shape") end)
    end

    assert byte_size(Tools.cut(String.duplicate("x", 20_000))) <= 16_384
  end

  test "bounded decoder rejects malformed framing, CRC, unsupported encodings, filters and bombs",
       %{root: root, ctx: ctx} do
    valid = png(1, 1, <<0, 1, 2, 3>>)

    for {name, bytes} <- [
          {"signature", "not png"},
          {"truncated", binary_part(valid, 0, 40)},
          {"crc", binary_part(valid, 0, byte_size(valid) - 1) <> <<0>>},
          {"trailing", valid <> "junk"},
          {"compressed_trailing",
           <<137, 80, 78, 71, 13, 10, 26, 10>> <>
             chunk("IHDR", <<1::32, 1::32, 8, 2, 0, 0, 0>>) <>
             chunk("IDAT", :zlib.compress(<<0, 1, 2, 3>>) <> "junk") <> chunk("IEND", "")},
          {"animation", png(1, 1, <<0, 1, 2, 3>>, chunk("acTL", <<1::32, 0::32>>))},
          {"duplicate_palette",
           png(1, 1, <<0, 1, 2, 3>>, chunk("PLTE", <<1, 2, 3>>) <> chunk("PLTE", <<4, 5, 6>>))},
          {"rgba", png(1, 1, <<0, 1, 2, 3>>, "", <<8, 6, 0, 0, 0>>)},
          {"interlaced", png(1, 1, <<0, 1, 2, 3>>, "", <<8, 2, 0, 0, 1>>)},
          {"filter", png(1, 1, <<5, 1, 2, 3>>)},
          {"short", png(1, 1, <<0, 1, 2>>)},
          {"bomb", png(1, 1, String.duplicate(<<0>>, 1_000_000))},
          {"zero", png(0, 1, <<0>>)},
          {"dimension", png(2049, 1, <<0>>)},
          {"empty", ""},
          {"bytes", String.duplicate("x", 131_073)}
        ] do
      File.write!(Path.join(root, name), bytes)
      result = Tools.run("view_image", %{"path" => name}, ctx)
      assert is_binary(result), name
      assert result =~ "error:"
      assert result =~ "external image"
      assert result =~ "131072"
    end

    for args <- [%{}, %{"path" => 42}, %{"path" => "absent"}, %{"path" => "."}] do
      assert Tools.run("view_image", args, ctx) =~ "error:"
    end
  end

  test "dimension, byte and filter inclusive bounds", %{root: root, ctx: ctx} do
    for w <- [1, 2047, 2048], filter <- 0..4 do
      bytes = png(w, 1, <<filter>> <> :binary.copy(<<0>>, 3 * w))
      File.write!(Path.join(root, "valid"), bytes)
      assert is_list(Tools.run("view_image", %{"path" => "valid"}, ctx))
    end

    File.write!(Path.join(root, "palette"), png(1, 1, <<0, 1, 2, 3>>, chunk("PLTE", <<1, 2, 3>>)))
    assert is_list(Tools.run("view_image", %{"path" => "palette"}, ctx))

    for n <- [131_071, 131_072] do
      base = png(1, 1, <<0, 0, 0, 0>>)

      bytes =
        png(
          1,
          1,
          <<0, 0, 0, 0>>,
          chunk("tEXt", "p\0" <> String.duplicate("x", n - byte_size(base) - 14))
        )

      assert byte_size(bytes) == n
      File.write!(Path.join(root, "valid"), bytes)
      assert is_list(Tools.run("view_image", %{"path" => "valid"}, ctx))
    end
  end

  test "compact events distinguish read, rejection, uncertain transport and completed delivery",
       %{root: root, ctx: ctx} do
    run = Kogen.Run.start(root)
    path = Path.join(root, "pixels")
    File.write!(path, png(1, 1, <<0, 1, 2, 3>>))
    result = Tools.run("view_image", %{"path" => path}, ctx)
    call = %{"call_id" => String.duplicate("Δ\n", 5000)}
    Image.read_event(call, result, "review", run)
    input = [Shape.output(call, result)]

    for facts <- [%{"http_status" => 400}, %{"event_kind" => "response.failed"}] do
      assert_raise Kogen.Error, fn ->
        Image.delivery(input, "review", run, fn ->
          raise Kogen.Error,
            class: "provider",
            reason: "rejected",
            detail: "synthetic",
            provider_failure: facts
        end)
      end
    end

    assert_raise RuntimeError, fn ->
      Image.delivery(input, "review", run, fn -> raise "uncertain" end)
    end

    response = %{response_metadata: %{"id" => "response-1"}}
    assert Image.delivery(input, "review", run, fn -> response end) == response
    lines = File.read!(run.log) |> String.split("\n", trim: true)
    events = Enum.map(lines, &JSON.decode!/1)

    assert Enum.map(events, & &1["status"]) == [
             "read",
             "failed",
             "failed",
             "unknown",
             "completed"
           ]

    assert List.last(events)["response_id"] == "response-1"

    for line <- lines do
      assert byte_size(line) <= 8192
      refute line =~ "data:image"
      refute line =~ Base.encode64(File.read!(path))
    end
  end
end
