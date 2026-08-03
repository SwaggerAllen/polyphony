defmodule Polyphony.Repo.Migrations.NormalizeUserEmails do
  @moduledoc """
  Bring stored addresses to the canonical form sign-in looks them up by.

  `normalize_email/1` lower-cased but never trimmed, so an address that arrived with
  surrounding whitespace — a phone keyboard leaves one on an autocompleted address
  readily enough — was stored with it. Sign-in is a silent lookup: no match sends no
  email, behind a screen that says one was sent either way, so the account simply
  could not be signed into and nothing said why.

  Fixing the lookup is not enough on its own; a row stored with a space stays
  unreachable until the row itself is fixed. Idempotent, and a no-op on a database
  where nothing was ever stored untrimmed.
  """
  use Ecto.Migration

  def up do
    # Guarded by the WHERE so it touches only rows that actually differ, which keeps
    # `updated_at` honest on every account that was already fine.
    execute("""
    UPDATE users
       SET email = lower(btrim(email))
     WHERE email IS DISTINCT FROM lower(btrim(email))
    """)
  end

  # Deliberately irreversible: the original whitespace is not recorded anywhere, and
  # restoring it would only recreate accounts nobody can sign in to.
  def down, do: :ok
end
