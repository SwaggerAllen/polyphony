defmodule PolyphonyWeb.SettingsLive do
  @moduledoc """
  Settings, ported from `ux/polyphony-settings-auth.html` — *everything about you, not
  your stories*.

  Reading preferences live in play; a campaign's spend limit lives in the campaign.
  This is the account itself.

  ## A number you can change

  The load-bearing fix. Error copy has said *you can raise it in Settings* for a long
  time, and both ceilings lived in app config — identical for everyone, editable only
  by a deploy. Now the daily one is the account's own (§B5), and the screen shows what
  hitting it will feel like **before** you hit it, because a cap met mid-scene is the
  worst possible moment to meet a control you've never seen.

  It reads as **turns remaining, not a percentage**: nobody knows what 86% of their
  budget feels like, and everybody knows what fourteen more turns feels like.

  ## Two limits, protecting against different things

  Your daily limit protects you from a runaway loop. A campaign's lifetime limit
  protects you from one story quietly eating the month. They fail differently, so they
  live in different places — the campaign's is in campaign settings, and each row in
  *where it went* links there.

  ## 18+ is eligibility, not a setting

  Everyone with an account has confirmed it; it's what having an account means. So it
  shows as locked rather than as a toggle, and there is nothing to change.

  ## Deliberately absent

  No automated-analysis toggle — there is nothing to toggle, since scene analysis is
  part of the under-18 work that isn't happening, and a switch for a feature that
  doesn't exist is worse than no switch (§4b.2). The §C opt-out seam stays in the
  domain for when such a feature exists, at which point the design places the control
  per campaign rather than per account.
  """
  use PolyphonyWeb, :live_view

  alias Polyphony.{Accounts, Campaigns, Costs, Library}
  alias Polyphony.Owner
  alias Polyphony.Notifications.Prefs
  alias PolyphonyWeb.Screens

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Settings", editing_cap: false, confirming_delete: false)
     |> refresh()}
  end

  defp refresh(socket) do
    user = Accounts.get(socket.assigns.current_user.id)
    cap = Costs.daily_cap(user)
    spent = Costs.spent_today(user.id)

    socket
    |> assign(
      current_user: user,
      cap: cap,
      spent_today: spent,
      fraction: fraction(spent, cap),
      notifications: notification_prefs(user),
      what_goes: what_goes(user),
      turns_left: Costs.turns_remaining(user),
      this_month: Costs.this_month(user.id),
      spend_rows: spend_rows(user),
      needs_reconsent: Accounts.needs_reconsent?(user.id),
      days_until_deletion: Accounts.days_until_deletion(user),
      username_free_in: username_free_in(user)
    )
  end

  # Per-campaign spend has never been shown anywhere, which is how one story eats a
  # month without anyone noticing until the cap bites. Each row carries its campaign's
  # *own* lifetime limit, because that's the number you'd want to change from here.
  defp spend_rows(user) do
    # Archived and trashed ones too. A row here is *where the money went*, and the
    # campaign's current shelf doesn't change that — leaving them out sent a filed-away
    # story's whole spend into the "outside any scene" bucket, which is the same
    # misattribution as not recording the campaign at all.
    campaigns =
      Owner.of(user)
      |> Campaigns.list(include_archived: true, include_deleted: true)
      |> Map.new(&{to_string(&1.id), &1})

    for row <- Costs.by_campaign(user.id) do
      case Map.get(campaigns, to_string(row.campaign_id)) do
        nil ->
          %{row | campaign_id: nil}
          |> Map.merge(%{
            name: "Writing characters and worlds",
            detail: "Outside any scene",
            id: nil
          })

        entry ->
          payload = Library.payload(entry) || %{}

          Map.merge(row, %{
            id: entry.id,
            name: Campaigns.name(entry),
            detail: campaign_detail(entry, payload)
          })
      end
    end
  end

  defp campaign_detail(entry, payload) do
    status = Campaigns.status_label(Campaigns.status(payload))
    lifetime = Costs.spent_campaign(entry.id)
    cap = Costs.campaign_cap(payload)

    "#{status} · #{Screens.Settings.money(lifetime)} all time of #{Screens.Settings.money(cap)}"
  end

  defp fraction(_spent, cap) when not is_integer(cap) or cap <= 0, do: 0.0
  defp fraction(spent, cap), do: min(spent / cap, 1.0)

  defp username_free_in(user) do
    case user.username_changed_at do
      nil ->
        nil

      last ->
        days = 30 - div(NaiveDateTime.diff(NaiveDateTime.utc_now(), last, :second), 86_400)
        if days > 0, do: days
    end
  end

  # ── Events ───────────────────────────────────────────────────────────────────

  def handle_event("edit_cap", _params, socket),
    do: {:noreply, assign(socket, editing_cap: not socket.assigns.editing_cap)}

  def handle_event("save_cap", %{"cap" => raw}, socket) do
    safe(socket, fn ->
      case Screens.Settings.parse_money(raw) do
        nil ->
          {:noreply, put_flash(socket, :error, "That didn't save — try a number like 5.00.")}

        cap ->
          {:ok, _} = Accounts.set_daily_cap(socket.assigns.current_user, cap)

          {:noreply,
           socket
           |> assign(editing_cap: false)
           |> put_flash(:info, "Limit raised to #{Screens.Settings.money(cap)}")
           |> refresh()}
      end
    end)
  end

  def handle_event("username", %{"username" => username}, socket) do
    safe(socket, fn ->
      case Accounts.change_username(socket.assigns.current_user, username) do
        {:ok, _} ->
          {:noreply, socket |> put_flash(:info, "That's your name now.") |> refresh()}

        {:error, :rate_limited} ->
          {:noreply, put_flash(socket, :error, "You can change this once a month.")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Taken. Try something else.")}
      end
    end)
  end

  def handle_event("consent", _params, socket) do
    safe(socket, fn ->
      for doc <- socket.assigns.needs_reconsent,
          do: Accounts.accept_consent(socket.assigns.current_user.id, doc)

      {:noreply, socket |> put_flash(:info, "Thanks — that's updated.") |> refresh()}
    end)
  end

  # Opt-out, so a row is written only to say no. Reading it back through `wants?/3`
  # rather than trusting the checkbox keeps the screen honest about what is stored.
  def handle_event("toggle_notification", %{"type" => type}, socket) do
    safe(socket, fn ->
      user = socket.assigns.current_user
      Prefs.set(user.id, type, not Prefs.wants?(user.id, type))
      {:noreply, assign(socket, notifications: notification_prefs(user))}
    end)
  end

  def handle_event("confirm_delete", _params, socket),
    do: {:noreply, assign(socket, confirming_delete: true)}

  def handle_event("keep_it", _params, socket),
    do: {:noreply, assign(socket, confirming_delete: false)}

  # Nothing is destroyed here — this starts a clock, and signing back in cancels it.
  def handle_event("delete_account", _params, socket) do
    safe(socket, fn ->
      {:ok, _} = Accounts.request_deletion(socket.assigns.current_user)

      {:noreply,
       socket
       |> assign(confirming_delete: false)
       |> put_flash(:info, "Your account will go in #{Accounts.deletion_window_days()} days.")
       |> refresh()}
    end)
  end

  def handle_event("cancel_delete", _params, socket) do
    safe(socket, fn ->
      {:ok, _} = Accounts.cancel_deletion(socket.assigns.current_user)
      {:noreply, socket |> put_flash(:info, "Glad you stayed.") |> refresh()}
    end)
  end

  # ── Render ───────────────────────────────────────────────────────────────────

  # Ordered by how much a person would miss it. Everything the system can send, minus
  # the one that isn't optional.
  defp notification_prefs(user) do
    Map.new(Screens.Settings.notification_types(), fn {type, _label, _note} ->
      {type, Prefs.wants?(user.id, type)}
    end)
  end

  # Counted rather than described, because "all your work" is easy to skim past and
  # "three campaigns, two worlds and forty-one characters" isn't.
  defp what_goes(current_user) do
    entries = Library.list_for_owner(Owner.of(current_user))
    by_kind = Enum.frequencies_by(entries, & &1.kind)

    parts =
      [
        count(by_kind["campaign"], "campaign", "campaigns"),
        count(by_kind["world_bible"], "world", "worlds"),
        count(by_kind["character"], "character", "characters")
      ]
      |> Enum.filter(& &1)

    case parts do
      [] ->
        "There's nothing in your library yet. The account goes all the same."

      parts ->
        Enum.join(parts, ", ") <> ". All of it, gone in #{Accounts.deletion_window_days()} days."
    end
  end

  defp count(nil, _one, _many), do: nil
  defp count(0, _one, _many), do: nil
  defp count(1, one, _many), do: "1 #{one}"
  defp count(n, _one, many), do: "#{n} #{many}"

  def render(assigns) do
    ~H"""
    <Screens.Settings.screen
      cap={@cap}
      confirming_delete={@confirming_delete}
      current_user={@current_user}
      days_until_deletion={@days_until_deletion}
      editing_cap={@editing_cap}
      fraction={@fraction}
      needs_reconsent={@needs_reconsent}
      notifications={@notifications}
      spend_rows={@spend_rows}
      spent_today={@spent_today}
      this_month={@this_month}
      turns_left={@turns_left}
      username_free_in={@username_free_in}
      what_goes={@what_goes}
    />
    """
  end
end
