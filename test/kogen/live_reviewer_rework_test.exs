defmodule Kogen.LiveReviewerReworkTest do
  @moduledoc """
  Independent live owner for the Build-only Reviewer-rework lifecycle. Keeping
  this case in a separate async module lets ExUnit overlap it with the connected
  Shape-to-Commit lifecycle without changing either causal chain.
  """
  use ExUnit.Case, async: true

  @moduletag :live
  @moduletag timeout: 900_000

  test "real reviewer rework resumes the same Developer and a fresh Reviewer accepts in a Build-only fixture" do
    Kogen.LiveShapeToBuildTest.run_reviewer_rework_case()
  end
end
