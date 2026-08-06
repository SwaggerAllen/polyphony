defmodule Polyphony.ReusableInvitesTest do
  @moduledoc """
  Invites that stay valid after they're used, and the way back out of one.

  Sign-up is invite-only and an invite redeemed exactly once, which is right for the
  door and wrong for the tester: putting a second and third account on a build is the
  job, and each one meant going back to the admin screen to mint again.

  So a reusable invite is the same row with the spend rule switched off — and because
  it is then a standing hole in an invite-only gate, it can be closed. Revocation is
  deliberately not a delete: an account that came in through an invite keeps its
  provenance either way.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{Accounts, Repo}
  alias Polyphony.Accounts.Invite

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    # `Accounts.role_atom/1` is `String.to_existing_atom` — deliberately, so a role
    # string out of the database can never mint an atom. The role atoms live in
    # `Roles`, and running this file alone never loads it.
    Code.ensure_loaded!(Polyphony.Accounts.Roles)
    :ok
  end

  defp admin do
    n = System.unique_integer([:positive])

    {:ok, user} =
      %{
        email: "a#{n}@x.io",
        username: "admin#{n}",
        role: "superadmin",
        attested_adult_at: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :microsecond)
      }
      |> Accounts.User.registration_changeset()
      |> Repo.insert()

    user
  end

  defp sign_up(token) do
    n = System.unique_integer([:positive])

    Accounts.register(%{
      email: "u#{n}@x.io",
      username: "user#{n}",
      invite_token: token,
      attested_adult: true,
      accepted_consents: Polyphony.Accounts.Consent.required_documents()
    })
  end

  # Someone has to exist before any of this, or the next sign-up bootstraps as
  # superadmin and needs no invite at all — which would make every assertion here pass
  # for the wrong reason.
  setup do: %{admin: admin()}

  describe "a reusable invite" do
    test "still works on the second and third account", %{admin: boss} do
      {:ok, invite} = Accounts.create_invite(boss, reusable: true)

      assert {:ok, _} = sign_up(invite.token)
      assert {:ok, _} = sign_up(invite.token)
      assert {:ok, _} = sign_up(invite.token)

      assert %{uses: 3} = Repo.get(Invite, invite.id)
    end

    test "and is still offered as open", %{admin: boss} do
      {:ok, invite} = Accounts.create_invite(boss, reusable: true)
      {:ok, _} = sign_up(invite.token)

      assert Accounts.open_invite(invite.token) != nil
    end

    test "names its most recent redeemer, and counts the rest", %{admin: boss} do
      {:ok, invite} = Accounts.create_invite(boss, reusable: true)
      {:ok, _first} = sign_up(invite.token)
      {:ok, second} = sign_up(invite.token)

      # One column, one person — so on a reusable invite it means *latest*, and `uses`
      # is what says there were others. The admin row reads both.
      row = Repo.get(Invite, invite.id)
      assert row.redeemed_by_id == second.id
      assert row.uses == 2
    end
  end

  describe "an ordinary invite" do
    test "is still single-use, and that is the default", %{admin: boss} do
      {:ok, invite} = Accounts.create_invite(boss)

      refute invite.reusable
      assert {:ok, _} = sign_up(invite.token)
      assert {:error, :invite_invalid} = sign_up(invite.token)
    end

    test "counts its one use, so an old row doesn't read as never used", %{admin: boss} do
      {:ok, invite} = Accounts.create_invite(boss)
      {:ok, _} = sign_up(invite.token)

      assert %{uses: 1} = Repo.get(Invite, invite.id)
    end
  end

  describe "revoking" do
    test "closes a reusable one for good", %{admin: boss} do
      {:ok, invite} = Accounts.create_invite(boss, reusable: true)
      {:ok, _} = sign_up(invite.token)

      {:ok, _} = Accounts.revoke_invite(boss, invite.id)

      assert Accounts.open_invite(invite.token) == nil
      assert {:error, :invite_invalid} = sign_up(invite.token)
    end

    test "closes an unused single-use one too — a code sent to the wrong address",
         %{admin: boss} do
      {:ok, invite} = Accounts.create_invite(boss)
      {:ok, _} = Accounts.revoke_invite(boss, invite.id)

      assert {:error, :invite_invalid} = sign_up(invite.token)
    end

    test "keeps the row, so an account keeps where it came from", %{admin: boss} do
      {:ok, invite} = Accounts.create_invite(boss, reusable: true)
      {:ok, user} = sign_up(invite.token)
      {:ok, _} = Accounts.revoke_invite(boss, invite.id)

      row = Repo.get(Invite, invite.id)
      assert row.redeemed_by_id == user.id
      assert row.uses == 1
    end

    test "twice is not an error — the question is whether it is closed", %{admin: boss} do
      {:ok, invite} = Accounts.create_invite(boss, reusable: true)
      {:ok, once} = Accounts.revoke_invite(boss, invite.id)
      {:ok, twice} = Accounts.revoke_invite(boss, invite.id)

      assert once.revoked_at == twice.revoked_at
    end

    test "is admin-only, like minting", %{admin: boss} do
      {:ok, invite} = Accounts.create_invite(boss, reusable: true)
      {:ok, ordinary} = sign_up(invite.token)

      assert {:error, :forbidden} = Accounts.revoke_invite(ordinary, invite.id)
      assert {:error, :forbidden} = Accounts.create_invite(ordinary, reusable: true)
      assert Accounts.open_invite(invite.token) != nil
    end

    test "an invite that isn't there is not found", %{admin: boss} do
      assert {:error, :not_found} = Accounts.revoke_invite(boss, 999_999_999)
    end
  end
end
