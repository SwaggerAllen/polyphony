defmodule Polyphony.Jobs.PurgeAccounts do
  @moduledoc """
  Delete accounts whose 30-day window has run out
  (`ux/polyphony-settings-auth.html` §04).

  The same argument as `PurgeTrash`: *everything goes, after 30 days* is a claim until
  something arrives at the end of it. Signing in cancels the request, so anything this
  job still finds is somebody who asked to leave and didn't come back.

  **What survives, deliberately.** Anyone who forked a published story keeps their copy
  — it's theirs now, a real copy in their own library with its own root, and taking it
  away would delete someone else's work to satisfy this one's request. What goes is the
  account and everything it owns, the published originals included.

  Runs daily on Oban's cron, and is idempotent: it acts on what is already past the
  window, so a missed run catches up and a double run finds nothing.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger

  alias Polyphony.Accounts

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Accounts.purge_expired_deletions() do
      0 ->
        :ok

      n ->
        Logger.info("[accounts] deleted #{n} account#{if n == 1, do: "", else: "s"} on request")
    end

    :ok
  end
end
