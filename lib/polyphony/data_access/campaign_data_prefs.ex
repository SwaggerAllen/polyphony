defmodule Polyphony.DataAccess.CampaignDataPrefs do
  @moduledoc """
  Per-campaign data-handling preferences (§C): currently just the proactive-analysis
  opt-out. Opt-out model — a row exists only for a campaign that has opted out.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "campaign_data_prefs" do
    field(:campaign_id, :string)
    field(:proactive_opt_out, :boolean, default: false)
    timestamps(type: :naive_datetime_usec)
  end

  def changeset(campaign_id, opt_out) do
    %__MODULE__{}
    |> change(campaign_id: to_string(campaign_id), proactive_opt_out: opt_out)
    |> unique_constraint(:campaign_id)
  end
end
