defmodule Kh.Version do
  @moduledoc "Build identity embedded by scripts/build-dev.sh."
  @sha System.get_env("KH_BUILD_SHA", "unbuilt")
  def sha, do: @sha
  def string, do: "0.1.0 (git #{@sha})"
end
