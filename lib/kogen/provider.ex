defmodule Kogen.Provider do
  @moduledoc "Adapts external language-model providers to the ProviderPort contract."
  use Boundary, deps: [Kogen.Contracts], exports: []
end
