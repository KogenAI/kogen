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
    # The lifecycle exercises whichever route the gate selected. The resolved
    # route below is the source of truth for root roles and native helpers.
    project_root = Path.expand("../..", __DIR__)

    assert {:ok, route} =
             Kogen.Intent.read_config(
               Path.join(project_root, ".kogen/config.yaml"),
               System.get_env("KOGEN_ROUTE")
             )

    assert is_binary(route.developer.model)
    assert is_binary(route.developer.effort)
    assert is_binary(route.reviewer.model)
    assert is_binary(route.reviewer.effort)
    assert is_binary(Kogen.Intent.role_config(route, :developer).helpers.worker.model)
    assert is_binary(Kogen.Intent.role_config(route, :developer).helpers.worker.effort)

    Kogen.LiveReviewerReworkFixture.run(route.route)
  end
end
