defmodule Polyphony.Repo.Migrations.AddReusableInvites do
  use Ecto.Migration

  @moduledoc """
  Invites that stay open after they're used, for hands-on testing.

  Sign-up is invite-only and an invite redeemed exactly once, which is right for the
  door and wrong for the tester: getting a second account onto a build meant going back
  to the admin screen and minting again, every time. A `reusable` invite is the same row
  with the spend rule switched off.

  `uses` because a reusable invite's redemption count is the only thing that tells you
  it is being used at all — `redeemed_by_id` can hold one person, and on a reusable
  invite that becomes "most recent", not "who".

  `revoked_at` because an invite that never spends itself is a standing hole in the
  gate. Applies to both kinds: a single-use invite sent to the wrong address had no way
  back either.
  """

  def change do
    alter table(:invites) do
      add(:reusable, :boolean, null: false, default: false)
      add(:uses, :integer, null: false, default: 0)
      add(:revoked_at, :naive_datetime_usec)
    end

    # Every invite already in the table was spent or not by `redeemed_at` alone, so the
    # count has to agree with that or an old redeemed row reads as never used.
    execute(
      "UPDATE invites SET uses = 1 WHERE redeemed_at IS NOT NULL",
      "SELECT 1"
    )
  end
end
