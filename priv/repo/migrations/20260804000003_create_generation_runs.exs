defmodule Polyphony.Repo.Migrations.CreateGenerationRuns do
  @moduledoc """
  Somewhere for a generation's answer to wait.

  Every ✦ button in the editors ran its provider call in a `start_async` task linked to
  the socket. The calls take seconds, which is exactly long enough for someone to switch
  apps — and when the socket goes, the task is killed and the answer is thrown away. The
  author comes back to a field that never filled in and a button that looks untouched,
  having been charged for the call.

  One row per (subject, control): the subject is the thing being written — a library
  entry, or a campaign — and the control is the button that asked. The unique index is
  the concurrency guard as well as the shape: one generation in flight per button, which
  is what the spinner already meant.

  `request` and `result` are opaque Erlang terms rather than columns, because what a
  generation takes and returns differs per operation and none of it is ever queried —
  only handed back to the screen that asked. The same shape `packet_drafts.packet` uses,
  for the same reason.
  """
  use Ecto.Migration

  def change do
    create table(:generation_runs) do
      add(:subject, :string, null: false)
      add(:key, :string, null: false)
      add(:op, :string, null: false)
      add(:request, :binary)
      add(:status, :string, null: false, default: "running")
      add(:result, :binary)
      timestamps(type: :naive_datetime_usec)
    end

    create(unique_index(:generation_runs, [:subject, :key]))
    # "What is still running, and what finished while nobody was looking?" — the two
    # questions a screen asks on mount.
    create(index(:generation_runs, [:subject, :status]))
  end
end
