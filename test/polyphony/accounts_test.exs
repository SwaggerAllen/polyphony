defmodule Polyphony.AccountsTest do
  @moduledoc """
  §B2: the sign-up gates, roles, invites, and consent end to end. The first account
  bootstraps as the sole superadmin; every later sign-up is gated by a single-use
  invite, an 18+ attestation, and current consent — all enforced offline.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{Accounts, Repo}
  alias Polyphony.Accounts.{User, Consent}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  @consents [:content_policy, :tos, :privacy]

  defp signup_attrs(attrs) do
    Map.merge(
      %{attested_adult: true, accepted_consents: @consents},
      Map.new(attrs)
    )
  end

  defp first_user do
    {:ok, user} = Accounts.register(signup_attrs(%{email: "boss@x.io", username: "boss"}))
    user
  end

  defp invite_token(admin) do
    {:ok, invite} = Accounts.create_invite(admin)
    invite.token
  end

  describe "first sign-up bootstraps the superadmin" do
    test "the first account becomes superadmin and needs no invite" do
      user = first_user()
      assert user.role == "superadmin"
      assert user.username == "boss"
      assert Accounts.adult_attested?(user)
    end

    test "a second superadmin cannot be minted, even racing the count (DB constraint)" do
      first_user()

      # Force a superadmin insert directly, bypassing register's count gate.
      cs =
        User.registration_changeset(%{
          email: "two@x.io",
          username: "two",
          role: "superadmin",
          attested_adult_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:microsecond)
        })

      assert {:error, changeset} = Repo.insert(cs)
      assert Keyword.has_key?(changeset.errors, :role)
    end
  end

  describe "sign-up gates (non-first account)" do
    setup do
      %{admin: first_user()}
    end

    test "attestation is required", %{admin: admin} do
      attrs = signup_attrs(%{email: "a@x.io", username: "aaa", invite_token: invite_token(admin)})

      assert {:error, :attestation_required} =
               Accounts.register(Map.put(attrs, :attested_adult, false))
    end

    test "a non-first sign-up requires an invite", %{admin: _admin} do
      attrs = signup_attrs(%{email: "a@x.io", username: "aaa"})
      assert {:error, :invite_required} = Accounts.register(attrs)
    end

    test "a bogus or already-spent invite is rejected", %{admin: admin} do
      assert {:error, :invite_invalid} =
               Accounts.register(
                 signup_attrs(%{email: "a@x.io", username: "aaa", invite_token: "nope"})
               )

      token = invite_token(admin)
      attrs1 = signup_attrs(%{email: "a@x.io", username: "aaa", invite_token: token})
      assert {:ok, _} = Accounts.register(attrs1)

      # Single-use: the same token cannot be redeemed twice.
      attrs2 = signup_attrs(%{email: "b@x.io", username: "bbb", invite_token: token})
      assert {:error, :invite_invalid} = Accounts.register(attrs2)
    end

    test "current consent must be accepted", %{admin: admin} do
      attrs =
        signup_attrs(%{email: "a@x.io", username: "aaa", invite_token: invite_token(admin)})
        |> Map.put(:accepted_consents, [:tos])

      assert {:error, :consent_required} = Accounts.register(attrs)
    end

    test "a fully-gated invitee registers as a plain user, and the invite is spent", %{
      admin: admin
    } do
      token = invite_token(admin)

      {:ok, user} =
        Accounts.register(signup_attrs(%{email: "a@x.io", username: "aaa", invite_token: token}))

      assert user.role == "user"
      assert Accounts.open_invite(token) == nil
      assert Accounts.needs_reconsent?(user.id) == []
    end
  end

  describe "role management (planned addition #4)" do
    setup do
      admin = first_user()
      token = invite_token(admin)

      {:ok, member} =
        Accounts.register(
          signup_attrs(%{email: "m@x.io", username: "member", invite_token: token})
        )

      %{superadmin: admin, member: member}
    end

    test "superadmin promotes a user to admin and can demote them back", %{
      superadmin: sa,
      member: m
    } do
      assert {:ok, promoted} = Accounts.promote_to_admin(sa, m)
      assert promoted.role == "admin"
      assert {:ok, demoted} = Accounts.demote_to_user(sa, promoted)
      assert demoted.role == "user"
    end

    test "a plain user cannot promote anyone", %{member: m} do
      assert {:error, :forbidden} = Accounts.promote_to_admin(m, m)
    end

    test "a regular admin can promote but cannot demote a peer", %{superadmin: sa, member: m} do
      {:ok, admin} = Accounts.promote_to_admin(sa, m)

      token = invite_token(sa)

      {:ok, other} =
        Accounts.register(
          signup_attrs(%{email: "o@x.io", username: "other", invite_token: token})
        )

      {:ok, other_admin} = Accounts.promote_to_admin(admin, other)

      assert other_admin.role == "admin"
      assert {:error, :forbidden} = Accounts.demote_to_user(admin, other_admin)
    end

    test "the superadmin is un-demotable, even by themselves", %{superadmin: sa} do
      assert {:error, :forbidden} = Accounts.demote_to_user(sa, sa)
    end
  end

  describe "invites are admin-gated" do
    setup do
      admin = first_user()
      token = invite_token(admin)

      {:ok, member} =
        Accounts.register(
          signup_attrs(%{email: "m@x.io", username: "member", invite_token: token})
        )

      %{admin: admin, member: member}
    end

    test "a plain user cannot mint invites", %{member: m} do
      assert {:error, :forbidden} = Accounts.create_invite(m)
    end
  end

  describe "consent re-prompt on version bump" do
    test "registration records current consent, so a fresh account needs none" do
      user = first_user()
      assert Accounts.needs_reconsent?(user.id) == []
    end

    test "an unaccepted/stale document surfaces, and accepting current clears it" do
      # A bare user (no registration-time consents) needs all documents.
      {:ok, user} =
        Repo.insert(
          User.registration_changeset(%{
            email: "c@x.io",
            username: "consenter",
            role: "superadmin",
            attested_adult_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:microsecond)
          })
        )

      assert Enum.sort(Accounts.needs_reconsent?(user.id)) == Enum.sort(@consents)

      # A stale (version 0) acceptance still counts as needing reconsent (0 < current).
      stale = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:microsecond)
      Repo.insert!(Consent.changeset(user.id, :content_policy, 0, stale))
      assert :content_policy in Accounts.needs_reconsent?(user.id)

      # Accepting the current version clears exactly that document.
      Accounts.accept_consent(user.id, :content_policy)
      refute :content_policy in Accounts.needs_reconsent?(user.id)
    end
  end

  describe "username rate limit" do
    test "cannot change again within the interval" do
      user = first_user()
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:microsecond)
      {:ok, renamed} = Accounts.change_username(user, "boss2", now: now)
      assert renamed.username == "boss2"

      soon = NaiveDateTime.add(now, 60)
      assert {:error, :rate_limited} = Accounts.change_username(renamed, "boss3", now: soon)

      later = NaiveDateTime.add(now, 31 * 24 * 60 * 60)
      assert {:ok, again} = Accounts.change_username(renamed, "boss3", now: later)
      assert again.username == "boss3"
    end
  end
end
