defmodule Polyphony.Repo.Migrations.BackfillGroupCampaigns do
  @moduledoc """
  One-time backfill: give every existing group the campaign it belongs to (STR-68).

  A group now carries `campaign_id`, and that is the key a campaign hub filters on.
  Before it, the hub read *every group the author owned*, so a second campaign's
  collectives appeared on the first campaign's hub and the count in the card header was
  the library's count. Nothing in the schema changes here — a group is a library entry
  whose payload is an Erlang term — so this rewrites payloads rather than adding a
  column.

  **App code rather than SQL**, for the reason `20260804000005` gives at more length: the
  answer lives inside an encoded blob, so no query can read it, and a decoder inlined
  into a migration is the same coupling with none of the tests.
  `Polyphony.Groups.backfill_campaigns/1` is pinned by `Polyphony.GroupsBackfillTest`,
  including the cases where it must decline to answer.

  **Groups it can't place are trashed.** A group belonging to no campaign is not a state
  this app supports — it appears on no hub, so it is unreachable from the story it was
  written for, and keeping the read paths that tolerate one means carrying compatibility
  logic for a class `Groups.create/3` now refuses to produce. Guessing a campaign would
  be worse: that files somebody's writing inside a story it was never part of, where it
  looks like it belongs, which is the one error here that doesn't announce itself.

  **Trashed, not purged** — `soft_delete/2`, so anything this catches that somebody
  actually wanted is one Restore away on the trash shelf and `Jobs.PurgeTrash` finishes
  on the ordinary 30-day clock. This runs unattended over every row, and irreversibility
  is not a property to hand that. The expected result on the deployment this was written
  for is zero rows either way.

  Safe to run twice: it only looks at live groups whose `campaign_id` is nil.
  """
  use Ecto.Migration

  require Logger

  def up do
    %{placed: placed, trashed: trashed} = Polyphony.Groups.backfill_campaigns(repo: repo())

    case {placed, trashed} do
      {[], []} ->
        Logger.info("[migrate] group campaigns: nothing to do")

      _ ->
        Logger.info(
          "[migrate] group campaigns: placed #{length(placed)} " <>
            "(#{Enum.map_join(placed, ", ", &"##{&1.id}→##{&1.campaign_id}")}), " <>
            "trashed #{length(trashed)} belonging to no campaign " <>
            "(#{Enum.map_join(trashed, ", ", &"##{&1}")}) — restorable for " <>
            "#{Polyphony.Library.retention_days()} days"
        )
    end
  end

  # Not reversible, and nothing is lost by that: `campaign_id` is derived from data the
  # rows still carry (`world_bible_id` and `member_ids`), so a rollback would clear a
  # field this could rebuild, while the reads that predate it ignore it entirely.
  def down, do: :ok
end
