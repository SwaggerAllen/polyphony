defmodule Polyphony.Repo.Migrations.RetargetSuperadminToStrutcoDomain do
  @moduledoc """
  One-time repair: point the superadmin's address at `@strutco.net`.

  The second of these (see `20260803000006`, which moved `@proton.me` → `@pm.me`), and
  the same reasoning: sign-in is magic-link only, so an address that doesn't reach
  anyone is an account nobody can get into, with no password to fall back on. A
  migration runs exactly once, is recorded in `schema_migrations` so a redeploy can't
  repeat it, and `MIGRATE_ON_BOOT` already runs migrations at startup.

  **Whatever domain it currently has**, rather than a specific one. The previous
  migration means the row is on `@pm.me` in the deployment this was written for — but
  a database restored from before it, or one where the account was created after, is
  on something else, and a `LIKE '%@pm.me'` guard would silently do nothing there. The
  local part is kept; only the domain moves.

  **Superadmin only.** There is exactly one, minted at first sign-up and un-demotable
  (`Polyphony.Accounts.Roles`), so this can't touch anyone else's address. It is a
  repair for one known row, not a policy about domains.

  Raw SQL rather than `Polyphony.Accounts`, deliberately. A migration is replayed
  against a fresh database months from now, when the schema it referenced may have
  moved on; SQL against a column that exists today keeps working.
  """
  use Ecto.Migration

  require Logger

  @domain "strutco.net"

  def up do
    # The NOT EXISTS guard is what stops this failing a deploy: `users.email` is
    # uniquely indexed, so if something already holds the target address the UPDATE
    # would raise and take the boot down with it. Better to change nothing and say so.
    #
    # `@[^@]*$` anchors on the **last** `@`, which is the only one that delimits a
    # domain — a local part may legally contain more.
    result =
      repo().query!(
        """
        UPDATE users u
           SET email = regexp_replace(u.email, '@[^@]*$', '@' || $1),
               updated_at = now()
         WHERE u.role = 'superadmin'
           AND u.email LIKE '%@%'
           AND u.email NOT LIKE '%@' || $1
           AND NOT EXISTS (
             SELECT 1 FROM users o
              WHERE o.id <> u.id
                AND o.email = regexp_replace(u.email, '@[^@]*$', '@' || $1)
           )
        """,
        [@domain]
      )

    case result.num_rows do
      0 ->
        Logger.info("[migrate] superadmin domain: already @#{@domain}, nothing to change")

      n ->
        Logger.info("[migrate] superadmin domain: moved #{n} account(s) to @#{@domain}")
    end
  end

  # Not reversible on purpose: the previous domain is the thing being corrected, and
  # restoring it would only restore an account nobody can sign in to.
  def down, do: :ok
end
