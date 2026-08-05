defmodule Polyphony.Repo.Migrations.AddResumeToBuildRuns do
  @moduledoc """
  What a Quick Build has already done, so a retry can carry on instead of starting over.

  The job shipped with `max_attempts: 1`, and the reasoning was sound as far as it went:
  a retry re-ran every provider call, charged for them again, and built a second world
  and a second cast on top of the ones the first attempt had already attached. But "the
  retry is unsafe" is an argument for fixing the retry, not for abandoning the longest
  and most expensive operation in the app to its first transient failure — which is
  precisely the one worth surviving.

  Two columns make it resumable:

    * `done` — the seed indexes whose character has been **written**. Recorded the moment
      the entry is persisted rather than when the seed is fully finished, which is what
      makes a resume never duplicate: a crash after the write skips that seed, a crash
      before it retries it, and a seed whose *generation* failed is retried too, because
      another go is exactly what it wanted.
    * `request` — the build's own arguments, so a run that exhausted its attempts can be
      started again from the screen. Without it, a failed build leaves a campaign that is
      no longer first-run, so the card that offers Quick Build is gone and there is no
      way back to it.
  """
  use Ecto.Migration

  def change do
    alter table(:build_runs) do
      add(:done, {:array, :integer}, null: false, default: [])
      add(:request, :binary)
    end
  end
end
