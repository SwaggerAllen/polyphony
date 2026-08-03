defmodule Polyphony.Repo.Migrations.AddModerationLanes do
  @moduledoc """
  Two things the admin screen needs the domain to be able to say
  (`ux/polyphony-admin.html`).

  **A suspension ends.** `suspended_at` recorded that one began and nothing recorded
  when it stops, so every suspension was indefinite and reinstatement was a manual act
  somebody had to remember. `suspended_until` makes *7 days* / *30 days* / *until we
  say otherwise* real, and a null with a live `suspended_at` is the honest indefinite.

  **A take-down spreads, and can't spread blind.** Taking down a snapshot has to reach
  the forks descended from it — but a fork may have diverged twenty scenes past
  anything objectionable, so deleting the family is wrong and ignoring it is worse.
  `hidden_at` and `review_reason` on a library entry give the third option the design
  asks for: it goes dark **and** into a review lane, where somebody looks.

  `hidden_at` also carries the other half of suspension: everything a suspended person
  has shared goes dark, unlisted included — otherwise they make a new account, open
  their own share link, and fork their way back in.
  """
  use Ecto.Migration

  def change do
    alter table(:users) do
      add(:suspended_until, :naive_datetime_usec)
    end

    alter table(:library_entries) do
      # Hidden ≠ private: the owner's own visibility setting is untouched and comes
      # back on its own when the hiding is lifted.
      add(:hidden_at, :naive_datetime_usec)
      add(:review_reason, :string)
    end

    create(index(:users, [:suspended_until]))
    create(index(:library_entries, [:hidden_at]))
  end
end
