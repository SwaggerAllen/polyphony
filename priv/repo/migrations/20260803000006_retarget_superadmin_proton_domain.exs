defmodule Polyphony.Repo.Migrations.RetargetSuperadminProtonDomain do
  @moduledoc """
  One-time repair: move the superadmin's address from `@proton.me` to `@pm.me`.

  The account was created with the wrong domain, and sign-in is magic-link only — so
  the link goes somewhere unread and there is no password to fall back on. The two
  alternatives were resetting the database (losing every campaign) or hand-editing a
  row over `rpc`, and a migration beats both: it runs exactly once, is recorded in
  `schema_migrations` so a redeploy can't repeat it, and `MIGRATE_ON_BOOT` already
  runs migrations at startup.

  **Superadmin only, and by suffix only.** Nothing else is in scope: this is a repair
  for one known-wrong row, not a policy about Proton addresses. A user who genuinely
  wants `@proton.me` keeps it.

  Raw SQL rather than `Polyphony.Accounts`, deliberately. A migration is replayed
  against a fresh database months from now, when the schema it referenced may have
  moved on; SQL against a column that exists today keeps working.
  """
  use Ecto.Migration

  require Logger

  @from "@proton.me"
  @to "@pm.me"

  def up do
    # The NOT EXISTS guard is what stops this failing a deploy: `users.email` is
    # uniquely indexed, so if something already holds the target address the UPDATE
    # would raise and take the boot down with it. Better to change nothing and say so.
    result =
      repo().query!(
        """
        UPDATE users u
           SET email = left(u.email, length(u.email) - length($1)) || $2,
               updated_at = now()
         WHERE u.role = 'superadmin'
           AND lower(u.email) LIKE '%' || $1
           AND NOT EXISTS (
             SELECT 1 FROM users o
              WHERE o.id <> u.id
                AND o.email = left(u.email, length(u.email) - length($1)) || $2
           )
        """,
        [@from, @to]
      )

    case result.num_rows do
      0 ->
        Logger.info("[migrate] superadmin domain: nothing to change")

      n ->
        Logger.info("[migrate] superadmin domain: moved #{n} account(s) #{@from} → #{@to}")
    end
  end

  # Not reversible on purpose. The original domain was the mistake; putting it back
  # would only restore an account nobody can sign in to.
  def down, do: :ok
end
