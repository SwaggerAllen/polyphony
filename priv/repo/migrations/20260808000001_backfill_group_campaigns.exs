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

  **Groups it can't place stay unplaced, and that is correct output.** A group written
  from the library belongs to no campaign; it stays visible on the library shelf so it
  can be deleted or re-filed. Guessing would file somebody's writing inside a story it
  was never part of, where it would look like it belonged — the one error here that
  isn't self-announcing.

  Safe to run twice: it only touches groups whose `campaign_id` is nil.
  """
  use Ecto.Migration

  require Logger

  def up do
    case Polyphony.Groups.backfill_campaigns(repo: repo()) do
      [] ->
        Logger.info("[migrate] group campaigns: nothing to backfill")

      placed ->
        Logger.info(
          "[migrate] group campaigns: placed #{length(placed)} " <>
            "(#{Enum.map_join(placed, ", ", &"##{&1.id}→##{&1.campaign_id}")})"
        )
    end
  end

  # Not reversible, and nothing is lost by that: `campaign_id` is derived from data the
  # rows still carry (`world_bible_id` and `member_ids`), so a rollback would clear a
  # field this could rebuild, while the reads that predate it ignore it entirely.
  def down, do: :ok
end
