defmodule Kogen.ShapingProbe.StaleLiveOwnerTest do
  use ExUnit.Case, async: true
  @moduletag :live
  test "calls a removed Kogen.Harness arity" do
    Kogen.Harness.launch_reviewer("p", "m", "e", nil, :removed_extra_arg)
  end
end
