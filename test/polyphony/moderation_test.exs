defmodule Polyphony.ModerationTest do
  @moduledoc """
  §B3: reporting + moderation. Tested hardest are the two standing guarantees — every
  admin action is server-side authorized (a non-admin gets `:forbidden` and causes **no
  side effect**, including no audit row), and every successful admin action is audited
  and attributed. Plus takedown/flag, the reactive-access audit, and the report alert.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{Moderation, Library, Accounts, Repo}
  alias Polyphony.Accounts.User
  alias Polyphony.Moderation.Report

  defmodule TestNotifier do
    @behaviour Polyphony.Moderation.Notifier
    defp pid, do: Application.get_env(:polyphony, :mod_test_pid)
    @impl true
    def report_filed(report), do: send(pid(), {:report_filed, report.id}) && :ok
    @impl true
    def owner_warned(report, msg), do: send(pid(), {:owner_warned, report.id, msg}) && :ok
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Application.put_env(:polyphony, :mod_test_pid, self())
    Application.put_env(:polyphony, :moderation_notifier, TestNotifier)

    on_exit(fn ->
      Application.delete_env(:polyphony, :mod_test_pid)
      Application.delete_env(:polyphony, :moderation_notifier)
    end)

    :ok
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

  # A published library entry owned by `owner`, plus an open report against it.
  defp reported_entry(reporter, owner, reason) do
    entry =
      Library.put(%{
        owner_id: owner.id,
        kind: "campaign",
        visibility: "public",
        payload: %{title: "a scene"}
      })

    {:ok, report} =
      Moderation.file_report(reporter, %{
        item_type: "library_entry",
        item_id: entry.id,
        owner_id: owner.id,
        reason: reason,
        detail: "please review"
      })

    {entry, report}
  end

  describe "filing a report (a user action)" do
    test "an authenticated reporter files a report and the admin alert fires" do
      reporter = user("user", "reporter")
      owner = user("user", "owner")

      {_entry, report} = reported_entry(reporter, owner, "harassment")

      assert report.status == "open"
      assert_received {:report_filed, _id}
    end

    test "an unknown reason is rejected by the changeset" do
      reporter = user("user", "reporter")
      owner = user("user", "owner")

      assert {:error, changeset} =
               Moderation.file_report(reporter, %{
                 item_type: "library_entry",
                 item_id: 1,
                 owner_id: owner.id,
                 reason: "not_a_reason"
               })

      assert Keyword.has_key?(changeset.errors, :reason)
    end
  end

  describe "authorization — no admin action without the role, and no side effect" do
    setup do
      reporter = user("user", "reporter")
      owner = user("user", "owner")
      {entry, report} = reported_entry(reporter, owner, "harassment")
      %{plain: user("user", "nobody"), owner: owner, entry: entry, report: report}
    end

    test "a non-admin is forbidden from every resolution action", ctx do
      p = ctx.plain

      assert {:error, :forbidden} = Moderation.dismiss(p, ctx.report)
      assert {:error, :forbidden} = Moderation.take_down(p, ctx.report, "nope")
      assert {:error, :forbidden} = Moderation.warn_owner(p, ctx.report, "hi")
      assert {:error, :forbidden} = Moderation.suspend_user(p, ctx.report)
      assert {:error, :forbidden} = Moderation.access_report_content(p, ctx.report)
    end

    test "a forbidden action writes no audit row and changes no state", ctx do
      p = ctx.plain
      assert {:error, :forbidden} = Moderation.take_down(p, ctx.report, "nope")

      assert Moderation.audit_trail(p.id) == []
      # The reported entry stays published; the report stays open.
      assert Library.get(ctx.entry.id).visibility == "public"
      assert Moderation.get_report(ctx.report.id).status == "open"
    end
  end

  describe "resolution actions (admin) are audited and attributed" do
    setup do
      admin = user("admin", "mod")
      reporter = user("user", "reporter")
      owner = user("user", "owner")
      %{admin: admin, reporter: reporter, owner: owner}
    end

    test "take_down unpublishes, records the reason, marks actioned, and audits", ctx do
      {entry, report} = reported_entry(ctx.reporter, ctx.owner, "harassment")

      assert {:ok, resolved} = Moderation.take_down(ctx.admin, report, "violates rules")
      assert resolved.status == "actioned"
      assert resolved.resolution == "takedown"
      assert resolved.resolution_reason == "violates rules"
      assert resolved.resolved_by_id == ctx.admin.id

      assert Library.get(entry.id).visibility == "private"

      # A non-absolute takedown does NOT flag the account.
      refute Accounts.flagged_for_review?(Accounts.get(ctx.owner.id))

      assert [%{action: "takedown", target_type: "report"}] = Moderation.audit_trail(ctx.admin.id)
    end

    test "an absolute-line takedown also flags the owning account", ctx do
      {_entry, report} = reported_entry(ctx.reporter, ctx.owner, "csam")

      assert Report.absolute_line?(report.reason)
      assert {:ok, _} = Moderation.take_down(ctx.admin, report, "absolute line")
      assert Accounts.flagged_for_review?(Accounts.get(ctx.owner.id))
    end

    test "suspend_user suspends the owner and actions the report", ctx do
      {_entry, report} = reported_entry(ctx.reporter, ctx.owner, "harassment")

      assert {:ok, resolved} = Moderation.suspend_user(ctx.admin, report)
      assert resolved.resolution == "suspend"
      assert Accounts.suspended?(Accounts.get(ctx.owner.id))
    end

    test "dismiss closes the report without unpublishing", ctx do
      {entry, report} = reported_entry(ctx.reporter, ctx.owner, "harassment")

      assert {:ok, resolved} = Moderation.dismiss(ctx.admin, report)
      assert resolved.status == "dismissed"
      assert Library.get(entry.id).visibility == "public"
    end

    test "warn_owner notifies the owner and audits, leaving the report open", ctx do
      {_entry, report} = reported_entry(ctx.reporter, ctx.owner, "harassment")

      assert {:ok, _} = Moderation.warn_owner(ctx.admin, report, "please stop")
      assert_received {:owner_warned, id, "please stop"} when id == report.id
      assert Moderation.get_report(report.id).status == "open"
      assert [%{action: "warn"}] = Moderation.audit_trail(ctx.admin.id)
    end
  end

  describe "reactive access (§C) — a report grants scoped, audited content access" do
    test "viewing a report in context returns the owner's entries and logs the access" do
      admin = user("admin", "mod")
      reporter = user("user", "reporter")
      owner = user("user", "owner")
      {_entry, report} = reported_entry(reporter, owner, "harassment")
      # A second, private entry the owner never published.
      Library.put(%{
        owner_id: owner.id,
        kind: "character",
        visibility: "private",
        payload: %{n: 1}
      })

      assert {:ok, entries} = Moderation.access_report_content(admin, report)
      assert length(entries) == 2

      assert [%{action: "content_access", target_type: "report", metadata: meta}] =
               Moderation.audit_trail(admin.id)

      assert meta["owner_id"] == owner.id
    end
  end
end
