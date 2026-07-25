defmodule Polyphony.Costs.Ledger do
  @moduledoc """
  The append-only spend ledger (§B5): one row per billable event, attributed to a
  user and a campaign. Sums over it feed the cost dashboard and the circuit breaker.
  `amount` is in abstract cost units (micro-cents), so the ledger is billing-ready.
  """
  use Ecto.Schema
  import Ecto.Query

  schema "cost_ledger" do
    field(:user_id, :id)
    field(:campaign_id, :string)
    field(:amount, :integer, default: 0)
    field(:kind, :string, default: "generation")
    field(:metadata, :map, default: %{})
    timestamps(type: :naive_datetime_usec, updated_at: false)
  end

  def put(repo, attrs), do: repo.insert!(struct(__MODULE__, attrs))

  @doc "Total spend by `user_id` at or after `since` (the rolling per-day window)."
  def sum_for_user_since(repo, user_id, since) do
    repo.one(
      from(l in __MODULE__,
        where: l.user_id == ^user_id and l.inserted_at >= ^since,
        select: coalesce(sum(l.amount), 0)
      )
    )
  end

  @doc "Total spend on `campaign_id` (lifetime)."
  def sum_for_campaign(repo, campaign_id) do
    repo.one(
      from(l in __MODULE__,
        where: l.campaign_id == ^to_string(campaign_id),
        select: coalesce(sum(l.amount), 0)
      )
    )
  end
end
