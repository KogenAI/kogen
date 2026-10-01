defmodule Kh.StreamTest do
  use ExUnit.Case, async: true

  test "SSE parser keeps fragmented frames until complete and joins data lines" do
    {[], buffer} = Kh.SSE.feed("", "event: message\r\ndata: {\"a\":")
    {frames, buffer} = Kh.SSE.feed(buffer, "1,\r\ndata: \"b\":2}\r\n\r\ndata: [DONE]")

    assert frames == ["{\"a\":1,\n\"b\":2}"]
    assert buffer == "data: [DONE]"
    assert Kh.SSE.feed(buffer, "\n\n") == {["[DONE]"], ""}
  end

  test "stream errors retain stable fatal versus retryable classification" do
    assert Kh.Provider.classify_stream_error("quota exceeded") == :fatal
    assert Kh.Provider.classify_stream_error("service unavailable") == :transient
  end
end
