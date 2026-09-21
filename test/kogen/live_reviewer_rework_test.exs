Code.require_file("../support/dependency_fixture.ex", __DIR__)
Code.require_file("../support/live_native_receipt_audit.ex", __DIR__)
Code.require_file("../support/live_rework_audit.ex", __DIR__)
Code.require_file("../support/root_profile_audit.ex", __DIR__)
Code.require_file("../support/live_reviewer_rework_fixture.ex", __DIR__)

defmodule Kogen.LiveReviewerReworkTest do
  @moduledoc """
  Independent live owner for the Build-only Reviewer-rework lifecycle. Keeping
  this case in a separate async module lets ExUnit overlap it with the connected
  Shape-to-Commit lifecycle without changing either causal chain.
  """
  use ExUnit.Case, async: true

  @moduletag :live
  @moduletag timeout: 1_200_000

  test "real reviewer rework resumes the same Developer and a fresh Reviewer accepts in a Build-only fixture" do
    Kogen.LiveReviewerReworkFixture.run()
  end
end
