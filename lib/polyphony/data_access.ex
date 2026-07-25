defmodule Polyphony.DataAccess do
  @moduledoc """
  The reactive/proactive access split (§C), enforced at the **data layer** — because
  content is stored unencrypted and the operator is a data controller.

  Two paths, and the whole point is that they differ:

    * **Proactive analysis** (batch scanning, quality/telemetry) is **opt-out-able**
      at both the **account** and **campaign** level, and the opt-out is enforced at
      *query time* (`proactive_eligible?/3`, `proactive_scope/2`), never merely in the
      UI. An opted-out account or campaign is simply not in the proactive working set.
    * **Reactive access** — a report grants scoped, audited, report-only visibility
      into the owning account (`Polyphony.Moderation.access_report_content/3`). It
      **must not** be blocked by the proactive opt-out: a user cannot opt out of being
      investigated when they are reported. `reactive_access/3` here is a thin,
      documented pass-through that deliberately never consults the opt-out flags.

  Account opt-out lives on the user (`Accounts`); campaign opt-out lives in
  `CampaignDataPrefs`.
  """

  import Ecto.Query

  alias Polyphony.{Repo, Accounts, Moderation}
  alias Polyphony.Accounts.User
  alias Polyphony.DataAccess.CampaignDataPrefs

  @doc "Set/clear a campaign's proactive-analysis opt-out (§C). Upserts the single row."
  def set_campaign_opt_out(campaign_id, opt_out, opts \\ []) do
    repo = repo(opts)
    cid = to_string(campaign_id)

    case repo.get_by(CampaignDataPrefs, campaign_id: cid) do
      nil -> repo.insert!(CampaignDataPrefs.changeset(cid, opt_out))
      row -> repo.update!(Ecto.Changeset.change(row, proactive_opt_out: opt_out))
    end
  end

  @doc "Has `campaign_id` opted out of proactive analysis?"
  def campaign_opted_out?(campaign_id, opts \\ []) do
    case repo(opts).get_by(CampaignDataPrefs, campaign_id: to_string(campaign_id)) do
      %CampaignDataPrefs{proactive_opt_out: v} -> v
      _ -> false
    end
  end

  @doc """
  May `user` + `campaign_id` be swept by **proactive** analysis? False if *either*
  the account or the campaign has opted out — the narrower opt-out wins, enforced
  here at the data layer.
  """
  @spec proactive_eligible?(User.t(), term(), keyword()) :: boolean()
  def proactive_eligible?(%User{} = user, campaign_id, opts \\ []) do
    not Accounts.proactive_opted_out?(user) and
      not (not is_nil(campaign_id) and campaign_opted_out?(campaign_id, opts))
  end

  @doc """
  Narrow a list of `%{user: %User{}, campaign_id: ...}` candidates to those eligible
  for proactive analysis — the query-time enforcement a proactive scanner must use.
  """
  def proactive_scope(candidates, opts \\ []) do
    Enum.filter(candidates, fn c ->
      proactive_eligible?(Map.fetch!(c, :user), Map.get(c, :campaign_id), opts)
    end)
  end

  @doc "The user ids that have opted out of proactive analysis (for a scanner's exclusion set)."
  def proactively_opted_out_user_ids(opts \\ []) do
    repo(opts).all(from(u in User, where: not is_nil(u.proactive_opt_out_at), select: u.id))
  end

  @doc """
  Reactive, report-triggered access — the §C guarantee that this path is **never**
  gated by the proactive opt-out. A thin pass-through to the audited moderation
  access so the split is explicit in the code, not just documentation.
  """
  def reactive_access(admin, report, opts \\ []),
    do: Moderation.access_report_content(admin, report, opts)

  defp repo(opts), do: Keyword.get(opts, :repo, Repo)
end
