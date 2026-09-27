defmodule Acme.Billing do
  def dispatch(invoice), do: invoice |> Invoice.build() |> Mailer.deliver()

  alias Acme.Ledger.Entry, as: Row
  alias Acme.{Clock, Mailer}

  defmodule Invoice do
    def build(id), do: Row.new(id) |> Clock.stamp(:utc)
  end

  def hook, do: &Mailer.deliver/2
end
