defmodule Polyphony.Repo.Migrations.TrashOrphanedCharacters do
  @moduledoc """
  One-time cleanup: put every character that belongs to no campaign in the trash.

  Three paths invented people and left them attached to nothing — a stub written from a
  relationship, a name mentioned mid-scene, and Quick Build's off-screen walk-ons. All
  three now put them on a campaign (`Polyphony.Campaigns.cast/3`), so no new ones can
  appear; this is the ones that already did. What they cost while they sit there: the
  library files them under *Not in a campaign*, the cast tab's "fill them in" prompt
  can't see them, and they show up in every "add a character" picker belonging to a
  story that never knew them.

  **Trashed, not purged.** `Library.trash_orphaned_characters/1` soft-deletes, so
  anything this catches that somebody actually wanted is one Restore away on the trash
  shelf, and `Jobs.PurgeTrash` finishes the job on the ordinary 30-day clock rather than
  this doing it irreversibly in a single pass. The expected result on the deployment
  this was written for is zero rows.

  **App code rather than raw SQL**, which departs from `20260804000001` and its
  reasoning — and the departure is forced rather than casual. A campaign's roster lives
  inside an Erlang-term `payload` blob, so no SQL can answer "is this character on
  anybody's list"; the only alternative is a decoder inlined here, which is the same
  coupling with none of the tests. `Library.orphaned_characters/1` is pinned by
  `LibraryOrphansTest`, including the two ways this could destroy data: a roster it
  can't read raises rather than counting as empty, and archived campaigns, trashed
  campaigns and published snapshots all still protect the people they hold.
  """
  use Ecto.Migration

  require Logger

  def up do
    orphans = Polyphony.Library.trash_orphaned_characters(repo: repo())

    case orphans do
      [] ->
        Logger.info("[migrate] orphaned characters: none, nothing to do")

      list ->
        Logger.info(
          "[migrate] orphaned characters: moved #{length(list)} to the trash " <>
            "(ids #{Enum.map_join(list, ", ", &to_string(&1.id))}) — restorable for " <>
            "#{Polyphony.Library.retention_days()} days"
        )
    end
  end

  # Not reversible: the rows are still there and still restorable, individually, from
  # the trash shelf — which is a better undo than a blanket one that would also restore
  # anything already in the trash for a reason.
  def down, do: :ok
end
