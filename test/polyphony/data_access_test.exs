defmodule Polyphony.DataAccessTest do
  @moduledoc """
  §C: the reactive/proactive access split, enforced at the data layer. Tested hardest
  is the asymmetry — an opted-out account is excluded from proactive scanning, yet a
  report still grants reactive access to that *same* account (opt-out never blocks
  investigation).
  """
  use ExUnit.Case, async: false

  alias Polyphony.{DataAccess, Accounts, Moderation, Library, Repo}
  alias Polyphony.Accounts.User

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp user(role, username) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:microsecond)

    {:ok, u} =
      Repo.insert(
        User.registration_changeset(%{
          email: "#{username}@x.io",
          username: username,
          role: role,
          attested_adult_at: now
        })
      )

    u
  end

  describe "proactive opt-out enforced at query time" do
    test "account opt-out makes the user ineligible; campaign opt-out does too" do
      una = user("user", "una")
      assert DataAccess.proactive_eligible?(una, "camp")

      opted = Accounts.set_proactive_opt_out(una, true)
      refute DataAccess.proactive_eligible?(opted, "camp")

      # A fresh account, but the campaign opts out.
      vna = user("user", "vna")
      DataAccess.set_campaign_opt_out("camp", true)
      refute DataAccess.proactive_eligible?(vna, "camp")
      assert DataAccess.proactive_eligible?(vna, "other_camp")
    end

    test "proactive_scope filters the opted-out candidates out of the working set" do
      keep = user("user", "keep")
      drop = user("user", "drop") |> Accounts.set_proactive_opt_out(true)

      scoped =
        DataAccess.proactive_scope([
          %{user: keep, campaign_id: "c1"},
          %{user: drop, campaign_id: "c1"}
        ])

      assert Enum.map(scoped, & &1.user.username) == ["keep"]
      assert DataAccess.proactively_opted_out_user_ids() == [drop.id]
    end
  end

  describe "reactive access ignores the opt-out (the §C guarantee)" do
    test "a report grants audited access to an account that opted out of proactive analysis" do
      admin = user("admin", "mod")
      reporter = user("user", "reporter")
      owner = user("user", "owner") |> Accounts.set_proactive_opt_out(true)

      # The opted-out owner is excluded from proactive scanning...
      refute DataAccess.proactive_eligible?(owner, "camp")

      # ...but a report still unlocks reactive, audited access to their content.
      Library.put(%{owner_id: owner.id, kind: "campaign", visibility: "public", payload: %{n: 1}})

      {:ok, report} =
        Moderation.file_report(reporter, %{
          item_type: "library_entry",
          item_id: 1,
          owner_id: owner.id,
          reason: "harassment"
        })

      assert {:ok, entries} = DataAccess.reactive_access(admin, report)
      assert length(entries) == 1
      # The access is audited (accountability), just like B3.
      assert [%{action: "content_access"}] = Moderation.audit_trail(admin.id)
    end
  end
end
