defmodule Kogen.Image do
  @moduledoc "Bounded read-only RGB8 PNG input and factual delivery telemetry."
  alias Kogen.{Error, WorkingContext}
  @limits "static non-interlaced RGB8 PNG, 1..131072 bytes, dimensions 1..2048"

  def read(args, ctx) do
    path = if is_map(args), do: args["path"]

    try do
      unless is_binary(path), do: raise(ArgumentError, "path must be a string")
      abs = Path.expand(path, ctx.root)

      case File.stat(abs) do
        {:ok, %{type: :regular}} -> :ok
        {:ok, _} -> raise ArgumentError, "artifact is not a regular file"
        {:error, reason} -> raise ArgumentError, "cannot stat artifact: #{reason}"
      end

      {:ok, io} = File.open(abs, [:read, :binary])

      bytes =
        try do
          case IO.binread(io, 131_073) do
            bytes when is_binary(bytes) and byte_size(bytes) in 1..131_072 -> bytes
            _ -> raise ArgumentError, "original byte limit exceeded or empty/unreadable artifact"
          end
        after
          File.close(io)
        end

      {width, height} = validate(bytes)

      candidate =
        try do
          Kogen.Snapshot.tree(ctx.root, Kogen.Git.head(ctx.root), Map.get(ctx, :excluded, []))
        rescue
          _ -> "UNKNOWN"
        end

      metadata = %{
        version: 1,
        path: path,
        sha256: WorkingContext.hash(bytes),
        bytes: byte_size(bytes),
        format: "png",
        width: width,
        height: height,
        read_candidate: candidate,
        capture_candidate: "UNKNOWN",
        route: "UNKNOWN",
        viewport: "UNKNOWN",
        fixture_state: "UNKNOWN"
      }

      [
        %{"type" => "input_text", "text" => JSON.encode!(metadata)},
        %{
          "type" => "input_image",
          "image_url" => "data:image/png;base64," <> Base.encode64(bytes)
        }
      ]
    rescue
      e ->
        selected = if is_binary(path), do: String.slice(path, 0, 512), else: "(no selected path)"

        "error: #{selected}: unreadable/nonregular artifact or invalid PNG: #{Exception.message(e) |> String.slice(0, 512)}. Limits: #{@limits}. Prepare/export a supported image with an ordinary external image preparation/capture tool and select it again."
    end
  end

  defp validate(<<137, 80, 78, 71, 13, 10, 26, 10, rest::binary>>) do
    {w, h, compressed} = chunks(rest, nil, [], :header)
    raw = inflate(compressed, h * (1 + 3 * w))

    for <<row::binary-size(1 + 3 * ^w) <- raw>> do
      <<filter, _::binary>> = row
      unless filter in 0..4, do: raise(ArgumentError, "illegal scanline filter")
    end

    {w, h}
  end

  defp validate(_), do: raise(ArgumentError, "invalid PNG signature")

  defp chunks(
         <<size::32, type::binary-size(4), data::binary-size(size), crc::32, rest::binary>>,
         dim,
         idat,
         phase
       ) do
    unless :erlang.crc32(type <> data) == crc, do: raise(ArgumentError, "chunk CRC mismatch")

    unless Enum.all?(:binary.bin_to_list(type), &(&1 in ?A..?Z or &1 in ?a..?z)) and
             :binary.at(type, 2) in ?A..?Z,
           do: raise(ArgumentError, "invalid PNG chunk type")

    case {type, dim, phase} do
      {"IHDR", nil, :header} ->
        unless byte_size(data) == 13, do: raise(ArgumentError, "invalid IHDR length")
        <<w::32, h::32, encoding::binary>> = data

        unless encoding == <<8, 2, 0, 0, 0>>,
          do: raise(ArgumentError, "unsupported PNG encoding; requires non-interlaced RGB8")

        unless w in 1..2048 and h in 1..2048, do: raise(ArgumentError, "dimension limit exceeded")
        chunks(rest, {w, h}, idat, :before)

      {"PLTE", {_, _}, :before}
      when byte_size(data) in 3..768 and rem(byte_size(data), 3) == 0 ->
        chunks(rest, dim, idat, :palette)

      {"PLTE", _, _} ->
        raise ArgumentError, "duplicate, misplaced or invalid PLTE chunk"

      {"IDAT", {_, _}, p} when p in [:before, :palette, :data] ->
        chunks(rest, dim, [data | idat], :data)

      {"IEND", {w, h}, p}
      when p in [:data, :after] and idat != [] and data == "" and rest == "" ->
        {w, h, IO.iodata_to_binary(Enum.reverse(idat))}

      {t, {_, _}, p} when t not in ["IHDR", "IDAT", "IEND", "acTL", "fcTL", "fdAT"] ->
        <<first, _::binary>> = t

        unless first in ?a..?z,
          do: raise(ArgumentError, "unsupported critical chunk")

        chunks(rest, dim, idat, if(p == :data, do: :after, else: p))

      _ ->
        raise ArgumentError, "unsupported encoding, animation or invalid chunk order"
    end
  end

  defp chunks(_, _, _, _), do: raise(ArgumentError, "malformed or missing PNG chunks")

  defp inflate(data, limit) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, 15, :error)
      output = drain(z, data, limit, [])
      :ok = :zlib.inflateEnd(z)
      raw = IO.iodata_to_binary(output)

      unless byte_size(raw) == limit,
        do: raise(ArgumentError, "incorrect decompressed scanline size")

      raw
    after
      :zlib.close(z)
    end
  end

  defp drain(z, data, remaining, acc) do
    {status, out} = :zlib.safeInflate(z, data)
    n = IO.iodata_length(out)
    if n > remaining, do: raise(ArgumentError, "decompressed scanline bound exceeded")

    case status do
      :finished -> Enum.reverse([out | acc])
      :continue -> drain(z, <<>>, remaining - n, [out | acc])
    end
  end

  def entries(input) do
    Enum.flat_map(input, fn
      %{
        "type" => "function_call_output",
        "call_id" => id,
        "output" => [%{"type" => "input_text", "text" => text}, %{"type" => "input_image"}]
      } ->
        [{id, JSON.decode!(text)}]

      _ ->
        []
    end)
  end

  def guard!(body, owner) do
    if entries(body["input"]) != [] do
      m = WorkingContext.measure(body)

      unless m.fits do
        Error.raise!(
          "candidate",
          "context_budget_exceeded",
          "#{owner}: measured/mandatory #{m.rendered_bytes} bytes; ceiling 524288; reserve 131072 tokens. Frozen pixels retained in conversation. Use external image preparation or ordinary Refine and new exact approval.",
          1
        )
      end
    end
  end

  def read_event(call, result, owner, log) when is_list(result) do
    [{_, metadata}] = entries([Kogen.Shape.output(call, result)])

    emit(
      log,
      Map.merge(metadata, %{
        "event" => "image_read",
        "owner" => owner,
        "call_id" => call["call_id"],
        "status" => "read"
      })
    )
  end

  def read_event(_, _, _, _), do: :ok

  def delivery(input, owner, log, fun) do
    identity = Kogen.tmp_path("image-request") |> Path.basename()

    try do
      result = fun.()

      delivery_events(
        input,
        owner,
        log,
        identity,
        "completed",
        get_in(result, [:response_metadata, "id"])
      )

      result
    rescue
      e ->
        facts =
          case e do
            %Error{provider_failure: facts} -> facts || %{}
            _ -> %{}
          end

        rejected =
          is_integer(facts["http_status"]) or
            facts["event_kind"] in ["response.failed", "response.incomplete", "error"]

        delivery_events(
          input,
          owner,
          log,
          identity,
          if(rejected, do: "failed", else: "unknown"),
          nil
        )

        reraise e, __STACKTRACE__
    catch
      kind, reason ->
        delivery_events(input, owner, log, identity, "unknown", nil)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp delivery_events(input, owner, log, request, status, response) do
    for {id, meta} <- entries(input) do
      emit(log, %{
        "event" => "image_delivery",
        "owner" => owner,
        "call_id" => id,
        "sha256" => meta["sha256"],
        "status" => status,
        "request_id" => request,
        "response_id" => response
      })
    end
  end

  defp bounded_text(text, limit) when byte_size(text) <= limit, do: text

  defp bounded_text(text, limit) do
    prefix = binary_part(text, 0, limit)
    if String.valid?(prefix), do: prefix, else: bounded_text(text, limit - 1)
  end

  defp emit(log, event) do
    event =
      Map.new(event, fn {k, v} -> {k, if(is_binary(v), do: bounded_text(v, 256), else: v)} end)

    if log, do: Kogen.Run.log(log, event), else: Kogen.ShapeEvidence.record(event)
  end
end
