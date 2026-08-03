defmodule Polyphony.Jobs.PurgeTrash do
  @moduledoc """
  Purge library entries whose recovery window has run out (§2.13).

  The half of the countdown that makes it true. `Library` had `soft_delete/2`,
  `restore/2` and `purge/2` and nothing that ever called the last one — so *deleted
  things wait 30 days before they're really gone* was a claim with nothing behind it,
  and the trash row's "gone for good in 24 days" would have counted down to a day that
  never came.

  Runs daily on Oban's cron. Idempotent by construction: it purges what is already past
  the window, so a missed run catches up on the next one and a double run finds nothing
  the second time.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger

  alias Polyphony.Library

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Library.purge_expired() do
      0 ->
        :ok

      n ->
        Logger.info("[library] purged #{n} expired trash entr#{if n == 1, do: "y", else: "ies"}")
    end

    :ok
  end
end
