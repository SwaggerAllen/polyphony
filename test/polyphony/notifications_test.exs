defmodule Polyphony.NotificationsTest do
  @moduledoc """
  §B4: the notification sending path + preferences. v1 has one live trigger (admin
  report alerts, §B3), routed through here. Tested: the path records what it sends,
  preferences opt out, `force:` bypasses them for safety alerts, and a filed report
  reaches every admin.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{Notifications, Moderation, Repo}
  alias Polyphony.Notifications.Prefs
  alias Polyphony.Accounts.User

  defmodule TestTransport do
    @behaviour Polyphony.Notifications.Transport
    defp pid, do: Application.get_env(:polyphony, :notif_test_pid)
    @impl true
    def deliver_email(to, subject, _body) do
      send(pid(), {:email, to, subject})
      {:ok, :test}
    end
  end

  defmodule FailTransport do
    @behaviour Polyphony.Notifications.Transport
    @impl true
    def deliver_email(_to, _subject, _body), do: {:error, :smtp_down}
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Application.put_env(:polyphony, :notif_test_pid, self())
    on_exit(fn -> Application.delete_env(:polyphony, :notif_test_pid) end)
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

  describe "deliver/4 — the sending path" do
    test "delivers via the transport and records a sent notification" do
      u = user("user", "alice")

      assert {:ok, notif} =
               Notifications.deliver(u, :owner_warning, %{message: "hi"},
                 transport: TestTransport
               )

      assert notif.status == "sent"
      assert notif.recipient_id == u.id
      assert notif.sent_at != nil
      assert_received {:email, "alice@x.io", _subject}
      assert [%{status: "sent"}] = Notifications.history(u.id)
    end

    test "a transport failure records a failed notification and returns the error" do
      u = user("user", "bob")

      assert {:error, :smtp_down} =
               Notifications.deliver(u, :owner_warning, %{message: "hi"},
                 transport: FailTransport
               )

      assert [%{status: "failed"}] = Notifications.history(u.id)
    end

    test "an unknown type or missing email is rejected without sending" do
      u = user("user", "carol")
      assert {:error, :unknown_type} = Notifications.deliver(u, :not_a_type, %{})

      assert {:error, :no_email} =
               Notifications.deliver("   " |> String.trim(), :owner_warning, %{})

      refute_received {:email, _, _}
    end
  end

  describe "preferences (opt-out model)" do
    test "default is opted-in; a disabled pref skips delivery; force overrides it" do
      u = user("user", "dan")
      assert Prefs.wants?(u.id, :owner_warning)

      Prefs.set(u.id, :owner_warning, false)
      refute Prefs.wants?(u.id, :owner_warning)

      assert {:skipped, :opted_out} =
               Notifications.deliver(u, :owner_warning, %{message: "x"}, transport: TestTransport)

      refute_received {:email, _, _}
      assert [%{status: "skipped_opt_out"}] = Notifications.history(u.id)

      # A safety-critical alert forces past the opt-out.
      assert {:ok, _} =
               Notifications.deliver(u, :owner_warning, %{message: "x"},
                 transport: TestTransport,
                 force: true
               )

      assert_received {:email, "dan@x.io", _}
    end

    test "re-enabling a pref restores delivery" do
      u = user("user", "erin")
      Prefs.set(u.id, :owner_warning, false)
      Prefs.set(u.id, :owner_warning, true)
      assert Prefs.wants?(u.id, :owner_warning)
    end
  end

  describe "notify_admins/3 — the report-alert fan-out" do
    test "reaches every admin, forced past preferences" do
      admin1 = user("admin", "mod1")
      _admin2 = user("superadmin", "mod2")
      _plain = user("user", "nonadmin")

      # An admin who tried to opt out still gets the safety alert.
      Prefs.set(admin1.id, :report_alert, false)

      results =
        Notifications.notify_admins(:report_alert, %{report_id: 7, reason: "csam"},
          transport: TestTransport
        )

      assert length(results) == 2
      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert_received {:email, "mod1@x.io", _}
      assert_received {:email, "mod2@x.io", _}
    end
  end

  describe "§B3 → §B4 integration" do
    setup do
      Application.put_env(
        :polyphony,
        :moderation_notifier,
        Polyphony.Notifications.ModerationNotifier
      )

      Application.put_env(:polyphony, :notification_transport, TestTransport)

      on_exit(fn ->
        Application.delete_env(:polyphony, :moderation_notifier)
        Application.delete_env(:polyphony, :notification_transport)
      end)

      :ok
    end

    test "filing a report actually sends the admin alert through the sending path" do
      admin = user("admin", "mod")
      reporter = user("user", "reporter")
      owner = user("user", "owner")

      {:ok, _report} =
        Moderation.file_report(reporter, %{
          item_type: "library_entry",
          item_id: 1,
          owner_id: owner.id,
          reason: "harassment"
        })

      assert_received {:email, "mod@x.io", subject}
      assert subject =~ "New content report"
      assert [%{type: "report_alert", status: "sent"}] = Notifications.history(admin.id)
    end
  end
end
