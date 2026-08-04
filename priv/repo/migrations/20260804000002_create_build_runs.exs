defmodule Polyphony.Repo.Migrations.CreateBuildRuns do
  @moduledoc """
  Durable progress for a Quick Build.

  It used to live in the LiveView's assigns, driven by a `start_async` task linked to
  the socket. That made a long, expensive, *persisting* job depend on a browser tab
  staying open: backgrounding the page killed it mid-flight, and because the build
  writes the world to the library before anything associates it, what was left behind
  was an orphan world under the name the author was about to use. The next attempt
  then collided with it, and the campaign screen had no idea any of it had happened.

  One row per campaign, so "is a build running for this campaign?" is a read anyone
  can do — the screen the build was started from, the same screen on another device,
  or the same screen after a redeploy.
  """
  use Ecto.Migration

  def change do
    create table(:build_runs) do
      add(:campaign_id, :string, null: false)
      add(:status, :string, null: false, default: "running")
      add(:step, :integer, null: false, default: 0)
      add(:total, :integer, null: false, default: 1)
      add(:label, :string)
      # Why it failed, or what it made — the sentence the screen shows when the build
      # is over and the author wasn't watching.
      add(:detail, :text)
      timestamps(type: :naive_datetime_usec)
    end

    # One live build per campaign. The uniqueness is the concurrency control: a second
    # tap can't start a second build, and a job that finds a row it didn't write knows
    # it is the duplicate.
    create(unique_index(:build_runs, [:campaign_id]))
  end
end
