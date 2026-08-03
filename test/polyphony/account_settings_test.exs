defmodule Polyphony.AccountSettingsTest do
  @moduledoc """
  What the settings screen needs the domain to be able to say
  (`ux/polyphony-settings-auth.html`).

  Two of these were promises with nothing behind them:

    * **A cap you can actually change.** The error copy has said *you can raise it in
      Settings* for a long time, and both ceilings lived in app config — identical for
      everyone, editable only by a deploy.
    * **Leaving is a decision on a clock.** *Sign back in within 30 days and none of
      this happens* only means something if signing in cancels it and something arrives
      at the end of the window.

  And one that was already right, worth pinning so it stays that way: **refusing a
  signup must not create a row about the person refused**, and must not burn the invite.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{Accounts, Costs, Library, Owner, Repo}
  alias Polyphony.Accounts.Consent
  alias Polyphony.Costs.Ledger

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  # Inserted directly: these tests are about what happens *after* an account exists, and
  # the sign-up gates have their own tests (plus the last describe here, which drives
  # `register/2` on purpose).
  defp user(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      %{
        email: "u#{n}@example.com",
        username: "user#{n}",
        role: "user",
        attested_adult_at: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :microsecond)
      }
      |> Map.merge(attrs)
      |> Accounts.User.registration_changeset()
      |> Repo.insert()

    user
  end

  defp spend(user, campaign_id, amount, kind \\ "generation") do
    Costs.record(%{user_id: user.id, campaign_id: campaign_id, amount: amount, kind: kind})
  end

  describe "a cap you can change" do
    test "an account with no cap of its own is on the configured default" do
      u = user()

      assert u.daily_cap == nil
      assert Costs.daily_cap(u) == Costs.daily_cap(nil)
    end

    test "raising it is the account's own number, and it binds" do
      u = user()
      spend(u, "c1", 600)

      # Below its own ceiling of 500, the breaker would stop it…
      assert {:stop, %{scope: :daily}} = Costs.check(u.id, "c1", daily_cap: 500)

      {:ok, u} = Accounts.set_daily_cap(u, 1_000)
      assert Costs.daily_cap(u) == 1_000
      # …and once raised, the stored number is what actually binds.
      assert Costs.check(u.id, "c1") == :ok
    end

    test "clearing it puts you back on the default, not on zero" do
      u = user()
      {:ok, u} = Accounts.set_daily_cap(u, 1_000)
      {:ok, u} = Accounts.set_daily_cap(u, nil)

      assert u.daily_cap == nil
      assert Costs.daily_cap(u) > 0
    end

    test "a nonsense cap is refused rather than stored" do
      u = user()
      {:ok, u} = Accounts.set_daily_cap(u, 0)
      assert u.daily_cap == nil

      {:ok, u} = Accounts.set_daily_cap(u, -5)
      assert u.daily_cap == nil
    end

    test "a campaign carries its own lifetime ceiling, separate from the daily one" do
      owner = Owner.coerce(System.unique_integer([:positive]))

      entry =
        Library.put(%{
          owner: owner,
          kind: "campaign",
          payload: %{kind: :campaign, name: "The Salt Line", spend_cap: 2_000, scenes: []}
        })

      assert Costs.campaign_cap(Library.payload(entry)) == 2_000
      # A campaign wanting a bigger budget doesn't raise the number protecting the rest.
      assert Costs.campaign_cap(%{kind: :campaign}) == Costs.campaign_cap(nil)
    end
  end

  describe "where it went" do
    test "one row per campaign, biggest first, plus what was spent outside any scene" do
      u = user()
      spend(u, "salt", 1_200)
      spend(u, "salt", 200)
      spend(u, "low", 590)
      spend(u, nil, 122, "authoring")

      rows = Costs.by_campaign(u.id)

      assert [%{campaign_id: "salt", amount: 1_400}, %{campaign_id: "low", amount: 590} | rest] =
               rows

      # Writing characters and worlds is a real row, not a rounding error.
      assert [%{campaign_id: nil, amount: 122}] = rest
    end

    test "this month is a calendar month, not a rolling window" do
      u = user()
      spend(u, "salt", 500)

      long_ago = NaiveDateTime.add(NaiveDateTime.utc_now(), -70 * 86_400, :second)
      Ledger.put(Repo, %{user_id: u.id, amount: 9_999, inserted_at: long_ago})

      assert Costs.this_month(u.id) == 500
    end

    test "one user's spend is not another's" do
      a = user()
      b = user()
      spend(a, "salt", 500)

      assert Costs.this_month(b.id) == 0
      assert Costs.by_campaign(b.id) == []
    end
  end

  describe "turns remaining, not a percentage" do
    test "estimated from what this account's generations have actually cost" do
      u = user()
      {:ok, u} = Accounts.set_daily_cap(u, 1_000)
      for _ <- 1..4, do: spend(u, "salt", 100)

      # 400 spent of 1000, averaging 100 a turn → six more.
      assert Costs.turns_remaining(u) == 6
    end

    test "no history means no number, because a made-up one is worse than none" do
      u = user()
      assert Costs.turns_remaining(u) == nil
    end

    test "and nothing left means nothing left" do
      u = user()
      {:ok, u} = Accounts.set_daily_cap(u, 200)
      spend(u, "salt", 200)

      assert Costs.turns_remaining(u) == nil
    end
  end

  describe "leaving" do
    test "asking destroys nothing — it starts a clock" do
      u = user()
      {:ok, u} = Accounts.request_deletion(u)

      assert u.deletion_requested_at != nil
      assert Accounts.days_until_deletion(u) == Accounts.deletion_window_days()
      # Still there, and still theirs.
      assert Accounts.get(u.id) != nil
    end

    test "the countdown rounds up and bottoms out at zero" do
      u = user()
      at = NaiveDateTime.add(NaiveDateTime.utc_now(), -(29 * 86_400 + 3600), :second)
      {:ok, u} = Accounts.request_deletion(u, now: at)

      assert Accounts.days_until_deletion(u) == 1

      old = NaiveDateTime.add(NaiveDateTime.utc_now(), -100 * 86_400, :second)
      {:ok, u} = Accounts.request_deletion(u, now: old)
      assert Accounts.days_until_deletion(u) == 0
    end

    test "changing your mind cancels it, and an account not leaving is a no-op" do
      u = user()
      {:ok, u} = Accounts.request_deletion(u)
      {:ok, u} = Accounts.cancel_deletion(u)

      assert u.deletion_requested_at == nil
      assert Accounts.days_until_deletion(u) == nil
      assert {:ok, ^u} = Accounts.cancel_deletion(u)
    end

    test "the purge takes what's past the window and leaves what isn't" do
      leaving = user()
      recent = user()
      staying = user()

      long_ago = NaiveDateTime.add(NaiveDateTime.utc_now(), -40 * 86_400, :second)
      {:ok, _} = Accounts.request_deletion(leaving, now: long_ago)
      {:ok, _} = Accounts.request_deletion(recent)

      assert Accounts.purge_expired_deletions() == 1

      assert Accounts.get(leaving.id) == nil
      assert Accounts.get(recent.id) != nil
      assert Accounts.get(staying.id) != nil
    end

    test "and it takes their library with them" do
      u = user()
      entry = Library.put(%{owner: Owner.of(u), kind: "campaign", payload: %{kind: :campaign}})

      long_ago = NaiveDateTime.add(NaiveDateTime.utc_now(), -40 * 86_400, :second)
      {:ok, _} = Accounts.request_deletion(u, now: long_ago)
      Accounts.purge_expired_deletions()

      assert Library.get(entry.id) == nil
    end

    test "but somebody else's fork is theirs now and stays" do
      author = user()
      forker = user()

      original =
        Library.put(%{owner: Owner.of(author), kind: "campaign", payload: %{kind: :campaign}})

      fork = Library.copy(original, Owner.of(forker))

      long_ago = NaiveDateTime.add(NaiveDateTime.utc_now(), -40 * 86_400, :second)
      {:ok, _} = Accounts.request_deletion(author, now: long_ago)
      Accounts.purge_expired_deletions()

      assert Library.get(original.id) == nil
      # Deleting somebody else's work to honour this request would be the wrong trade.
      assert Library.get(fork.id) != nil
    end

    test "running it twice finds nothing the second time" do
      u = user()
      long_ago = NaiveDateTime.add(NaiveDateTime.utc_now(), -40 * 86_400, :second)
      {:ok, _} = Accounts.request_deletion(u, now: long_ago)

      assert Accounts.purge_expired_deletions() == 1
      assert Accounts.purge_expired_deletions() == 0
    end
  end

  describe "turning someone away costs nothing to store" do
    test "an unattested signup makes no account at all" do
      before = Accounts.count()

      assert {:error, :attestation_required} =
               Accounts.register(%{
                 email: "under18@example.com",
                 username: "kid",
                 attested_adult: false,
                 accepted_consents: Consent.required_documents()
               })

      # Refusing someone must not create a row about them.
      assert Accounts.count() == before
      assert Accounts.get_by_email("under18@example.com") == nil
    end

    test "and it doesn't burn the invite" do
      # `role_atom/1` uses `binary_to_existing_atom`, so the vocabulary has to be loaded.
      _ = Polyphony.Accounts.Roles.roles()
      admin = user(%{role: "superadmin"})
      {:ok, invite} = Accounts.create_invite(admin)

      assert {:error, :attestation_required} =
               Accounts.register(%{
                 email: "under18@example.com",
                 username: "kid",
                 attested_adult: false,
                 invite_token: invite.token,
                 accepted_consents: Consent.required_documents()
               })

      # Whoever sent it can pass it on; nobody has to ask for a replacement.
      assert Accounts.open_invite(invite.token) != nil
    end
  end
end
