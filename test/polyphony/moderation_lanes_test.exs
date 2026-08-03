defmodule Polyphony.ModerationLanesTest do
  @moduledoc """
  What the admin screen needs the domain to be able to say
  (`ux/polyphony-admin.html`).

  Four things, and two of them are new behaviour rather than new reads:

    * **A take-down spreads, and can't spread blind.** The public copy and the
      author's own, plus every fork descended from it — which can't be deleted
      outright, because a fork may have diverged twenty scenes past anything
      objectionable. So it goes dark *and* into a review lane, where somebody looks.
    * **A suspension hides everything shared, unlisted included.** Otherwise a
      suspended person makes a new account, opens their own share link, and forks their
      way back in. Starting again should mean starting again.
    * **Child safety is its own lane** — never a filter on a general queue.
    * **Reinstatement and lifting exist at all.** An indefinite suspension with no way
      back is a deletion nobody agreed to.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{Accounts, Campaigns, Library, Moderation, Owner, Repo}
  alias Polyphony.Accounts.User

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    _ = Polyphony.Accounts.Roles.roles()
    :ok
  end

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
      |> User.registration_changeset()
      |> Repo.insert()

    user
  end

  defp admin, do: user(%{role: "admin"})

  defp published(owner, visibility \\ "public") do
    Library.put(%{
      owner: Owner.of(owner),
      kind: "campaign",
      visibility: visibility,
      frozen: true,
      payload: %{kind: :campaign, name: "The Long Quiet"}
    })
  end

  defp report(reporter, owner, entry, reason \\ "harassment") do
    {:ok, report} =
      Moderation.file_report(reporter, %{
        item_type: "library_entry",
        item_id: entry.id,
        owner_id: owner.id,
        reason: reason,
        detail: "please look"
      })

    report
  end

  describe "the queue's lanes" do
    test "child safety is its own list, always first, never a filter" do
      reporter = user()
      owner = user()
      entry = published(owner)

      report(reporter, owner, entry, "harassment")
      csam = report(reporter, owner, entry, "csam")

      lanes = Moderation.lanes()

      assert [%{id: id}] = lanes.urgent
      assert id == csam.id
      # And it isn't also sitting in the general list.
      refute Enum.any?(lanes.rest, &(&1.id == csam.id))
      assert length(lanes.rest) == 1
    end

    test "oldest first within a lane, because the alternative is never looking" do
      reporter = user()
      owner = user()
      entry = published(owner)

      first = report(reporter, owner, entry)
      Process.sleep(2)
      second = report(reporter, owner, entry)

      assert [%{id: a}, %{id: b}] = Moderation.lanes().rest
      assert a == first.id
      assert b == second.id
    end
  end

  describe "a take-down spreads" do
    test "the original goes dark and its forks go to review, not down with it" do
      admin = admin()
      owner = user()
      forker = user()

      original = published(owner)
      fork = Library.copy(original, Owner.of(forker))
      r = report(user(), owner, original)

      {:ok, _} = Moderation.take_down(admin, r, "it's about a real person")

      # The reported thing itself is unpublished.
      assert Library.get(original.id).visibility == "private"

      # The fork is hidden but **not** deleted, and it's in the lane.
      hidden_fork = Library.get(fork.id)
      assert Library.hidden?(hidden_fork)
      assert hidden_fork.review_reason == "fork_of_takedown"
      assert Library.get(fork.id) != nil

      assert [%{entry: %{id: id}}] = Moderation.review_lane()
      assert id == fork.id
    end

    test "a hidden fork is out of browse and off its share link" do
      admin = admin()
      owner = user()
      forker = user()

      original = published(owner)
      fork = Library.copy(original, Owner.of(forker))
      {:ok, fork} = Library.set_visibility(fork.id, "unlisted")
      token = fork.share_token

      {:ok, _} = Moderation.take_down(admin, report(user(), owner, original), "nope")

      refute Enum.any?(Library.list_public("campaign"), &(&1.id == fork.id))
      # The share link is the half that would otherwise stay open.
      assert Library.get_by_share_token(token) == nil
    end

    test "a fork that diverged can be cleared, and comes back as it was" do
      admin = admin()
      owner = user()
      forker = user()

      original = published(owner)
      fork = Library.copy(original, Owner.of(forker))
      {:ok, _} = Library.set_visibility(fork.id, "public")
      {:ok, _} = Moderation.take_down(admin, report(user(), owner, original), "nope")

      {:ok, _} = Moderation.leave_fork(admin, fork.id)

      refute Library.hidden?(Library.get(fork.id))
      # Hiding never touched their visibility, so it comes back as they set it.
      assert Library.get(fork.id).visibility == "public"
      assert Moderation.review_lane() == []
    end

    test "or taken down too, when it carries the same material" do
      admin = admin()
      owner = user()
      forker = user()

      original = published(owner)
      fork = Library.copy(original, Owner.of(forker))
      {:ok, _} = Moderation.take_down(admin, report(user(), owner, original), "nope")

      {:ok, _} = Moderation.take_down_fork(admin, fork.id, "same material")

      assert Library.get(fork.id).review_reason == "same material"
    end

    test "a non-admin gets nothing, and leaves no audit row behind" do
      nobody = user()
      owner = user()
      entry = published(owner)
      r = report(user(), owner, entry)

      assert {:error, :forbidden} = Moderation.take_down(nobody, r, "because")
      assert Library.get(entry.id).visibility == "public"
      assert Moderation.audit_trail(nobody.id) == []
    end
  end

  describe "a take-down removes the thing, not its listing" do
    test "it's gone from the owner's own library, not just from browse" do
      admin = admin()
      owner = user()
      entry = published(owner)

      assert Enum.any?(Library.list_for_owner(Owner.of(owner)), &(&1.id == entry.id))

      {:ok, _} = Moderation.take_down(admin, report(user(), owner, entry), "upheld")

      # The deleted experience: it isn't in their library any more.
      refute Enum.any?(Library.list_for_owner(Owner.of(owner)), &(&1.id == entry.id))
      refute Enum.any?(Campaigns.list(Owner.of(owner)), &(&1.id == entry.id))
    end

    test "and the campaign it was published from goes with it" do
      admin = admin()
      owner = user()

      campaign =
        Library.put(%{
          owner: Owner.of(owner),
          kind: "campaign",
          payload: %{kind: :campaign, name: "The Long Quiet", character_ids: [], scenes: []}
        })

      snapshot =
        Library.publish_campaign(
          %{owner: Owner.of(owner), campaign_id: campaign.id, characters: [], arc: []},
          visibility: "public"
        )

      {:ok, _} = Moderation.take_down(admin, report(user(), owner, snapshot), "upheld")

      # She loses the campaign, not just its listing.
      assert Library.hidden?(Library.get(campaign.id))
      refute Enum.any?(Library.list_for_owner(Owner.of(owner)), &(&1.id == campaign.id))
    end

    test "moderation can still see it — that's what the §C grant is for" do
      admin = admin()
      owner = user()
      entry = published(owner)
      r = report(user(), owner, entry)

      {:ok, _} = Moderation.take_down(admin, r, "upheld")
      {:ok, entries} = Moderation.access_report_content(admin, r)

      assert Enum.any?(entries, &(&1.id == entry.id))
    end

    test "and a purge still takes it, because a purge has to be complete" do
      admin = admin()
      owner = user()
      entry = published(owner)
      {:ok, _} = Moderation.take_down(admin, report(user(), owner, entry), "upheld")

      :ok = Accounts.purge_account(Accounts.get(owner.id))

      assert Library.get(entry.id) == nil
    end

    test "lifting it puts everything back where the owner had it" do
      admin = admin()
      owner = user()
      entry = published(owner)
      {:ok, _} = Moderation.take_down(admin, report(user(), owner, entry), "upheld")

      {:ok, _} = Moderation.leave_fork(admin, entry.id)

      assert Enum.any?(Library.list_for_owner(Owner.of(owner)), &(&1.id == entry.id))
    end
  end

  describe "suspension" do
    test "hides everything shared — public and unlisted both" do
      admin = admin()
      owner = user()

      public = published(owner, "public")
      unlisted = published(owner, "unlisted")
      private = published(owner, "private")

      {:ok, _} = Moderation.suspend_user(admin, report(user(), owner, public), 30)

      assert Library.hidden?(Library.get(public.id))
      assert Library.hidden?(Library.get(unlisted.id))
      # Nothing of theirs is deleted, and what was never shared is untouched.
      refute Library.hidden?(Library.get(private.id))
      assert Library.get(public.id) != nil
    end

    test "it ends, and a lapsed one stops binding without anybody lifting it" do
      owner = user()
      Accounts.suspend(owner, 7)

      reloaded = Accounts.get(owner.id)
      assert Accounts.suspension_active?(reloaded)
      assert Accounts.suspension_days_left(reloaded) == 7

      # A week later it simply isn't a suspension any more.
      later = NaiveDateTime.add(NaiveDateTime.utc_now(), 8 * 86_400, :second)
      refute Accounts.suspension_active?(reloaded, now: later)
      assert Accounts.suspension_days_left(reloaded, now: later) == 0
    end

    test "until we say otherwise is a real choice, not the only one" do
      owner = user()
      Accounts.suspend(owner, nil)

      reloaded = Accounts.get(owner.id)
      assert Accounts.suspension_active?(reloaded)
      assert Accounts.suspension_days_left(reloaded) == nil
    end

    test "lifting it brings back exactly what the owner had chosen" do
      admin = admin()
      owner = user()

      public = published(owner, "public")
      unlisted = published(owner, "unlisted")
      {:ok, _} = Moderation.suspend_user(admin, report(user(), owner, public), 30)

      {:ok, restored} = Moderation.lift_suspension(admin, Accounts.get(owner.id))

      refute Accounts.suspension_active?(restored)
      assert Library.get(public.id).visibility == "public"
      assert Library.get(unlisted.id).visibility == "unlisted"
      refute Library.hidden?(Library.get(public.id))
      refute Library.hidden?(Library.get(unlisted.id))
    end

    test "lifting doesn't un-hide a fork that's in the review lane for another reason" do
      admin = admin()
      owner = user()
      forker = user()

      original = published(owner)
      fork = Library.copy(original, Owner.of(forker))
      {:ok, _} = Moderation.take_down(admin, report(user(), owner, original), "nope")
      {:ok, _} = Moderation.suspend_user(admin, report(user(), owner, original), 7)

      {:ok, _} = Moderation.lift_suspension(admin, Accounts.get(owner.id))

      # Different lane, different reason — the fork is still waiting on somebody.
      assert Library.hidden?(Library.get(fork.id))
    end

    test "a suspended account can't be listed as un-suspended" do
      a = user()
      b = user()
      Accounts.suspend(a, 30)

      ids = Accounts.list_suspended() |> Enum.map(& &1.id)
      assert a.id in ids
      refute b.id in ids
    end
  end

  describe "context for a judgement call" do
    test "somebody's history reads both directions" do
      subject = user()
      other = user()
      admin = admin()

      against = report(other, subject, published(subject))
      {:ok, _} = Moderation.dismiss(admin, against)

      made = report(subject, other, published(other))
      {:ok, _} = Moderation.dismiss(admin, made)
      report(subject, other, published(other))

      history = Moderation.history(subject.id)

      assert length(history.against) == 1
      assert length(history.made) == 2
      # Someone whose reports are nearly all dismissed is a signal too.
      assert history.made_dismissed == 1
    end

    test "repeat dismissals on the same item are counted" do
      admin = admin()
      owner = user()
      entry = published(owner)

      for _ <- 1..3 do
        {:ok, _} = Moderation.dismiss(admin, report(user(), owner, entry))
      end

      latest = report(user(), owner, entry)

      # The fourth report on the same thing usually means somebody's campaigning.
      assert Moderation.previous_dismissals(latest) == 3
    end

    test "the audit trail carries privilege use, which is what it's for" do
      admin = admin()
      owner = user()
      r = report(user(), owner, published(owner))

      {:ok, _} = Moderation.access_report_content(admin, r)

      assert [%{action: "content_access"} | _] = Moderation.recent_audit()
    end
  end
end
