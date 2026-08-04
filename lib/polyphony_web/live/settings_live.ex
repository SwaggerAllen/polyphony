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

  alias Polyphony.{Accounts, Campaigns, Costs, Library, Owner}
  alias Polyphony.Notifications.Prefs
  alias PolyphonyWeb.{Kit, Layouts}

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
    campaigns = Map.new(Campaigns.list(Owner.of(user)), &{to_string(&1.id), &1})

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

    "#{status} · #{money(lifetime)} all time of #{money(cap)}"
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
      case parse_money(raw) do
        nil ->
          {:noreply, put_flash(socket, :error, "That didn't save — try a number like 5.00.")}

        cap ->
          {:ok, _} = Accounts.set_daily_cap(socket.assigns.current_user, cap)

          {:noreply,
           socket
           |> assign(editing_cap: false)
           |> put_flash(:info, "Limit raised to #{money(cap)}")
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

  def render(assigns) do
    ~H"""
    <Kit.frame class="flex flex-col min-h-[100dvh]">
      <Kit.header title={@current_user.username} subtitle={@current_user.email}>
        <:actions>
          <Layouts.nav_menu current_user={@current_user} />
        </:actions>
      </Kit.header>

      <div class="flex-1 min-h-0 overflow-y-auto">
        <Kit.sheet class="m-4">
          <%!-- Leaving is a decision on a clock, and while the clock runs it's the
                first thing the screen says. --%>
          <Kit.row :if={@days_until_deletion} class="px-4 py-3" style="background:var(--b2)">
            <div class="ttl text-[15px] font-semibold mb-1"><%= leaving_line(@days_until_deletion) %></div>
            <p class="text-[13px] leading-relaxed dim mb-2">
              Signing back in cancels it. So does this button.
            </p>
            <Kit.btn kind={:primary} size={:sm} type="button" phx-click="cancel_delete">
              Keep my account
            </Kit.btn>
          </Kit.row>

          <Kit.row :if={@needs_reconsent != []} class="px-4 py-3">
            <div class="ttl text-[15px] font-semibold mb-1">The policies changed</div>
            <p class="text-[13px] leading-relaxed dim mb-2">
              Worth a look before you carry on.
            </p>
            <Kit.btn size={:sm} type="button" phx-click="consent">I've read them</Kit.btn>
          </Kit.row>

          <.spending {assigns} />
          <.you {assigns} />
          <.notifications_section {assigns} />
          <.data_section {assigns} />
        </Kit.sheet>

        <.delete_confirm :if={@confirming_delete} {assigns} />
      </div>
    </Kit.frame>
    """
  end

  # ── Spending ─────────────────────────────────────────────────────────────────

  defp spending(assigns) do
    ~H"""
    <Kit.row class="px-4 py-3">
      <div class="flex items-center justify-between mb-2.5">
        <span class="lbl dim">Spending</span>
        <span class="text-[12px] dim"><%= money(@this_month) %> this month</span>
      </div>

      <div class="flex items-baseline justify-between mb-1.5">
        <span class="text-[13px] dim">Today</span>
        <span class="mono text-[14px]" style={spend_colour(@fraction)}>
          <%= money(@spent_today) %> of <%= money(@cap) %>
        </span>
      </div>
      <Kit.bar fraction={@fraction} colour={bar_colour(@fraction)} class="mb-2.5" />

      <%!-- Turns remaining, not a percentage. Nobody knows what 86% of their budget
            feels like. --%>
      <div :if={@turns_left && @fraction >= 0.8} class="flex items-start gap-1.5 mb-3">
        <Kit.dot colour="var(--lamp)" class="mt-1.5 shrink-0" />
        <span class="text-[11.5px] leading-relaxed"><%= turns_line(@turns_left) %></span>
      </div>

      <div
        :if={@fraction >= 1.0}
        class="rounded-lg p-2.5 mb-3"
        style="background:color-mix(in srgb,var(--pencil) 9%,transparent);border-left:2px solid var(--pencil)"
      >
        <div class="text-[12.5px] font-semibold mb-0.5">That's today's limit</div>
        <p class="text-[12px] leading-relaxed dim">
          Nothing will generate until it resets, or until you raise it. Your scenes are
          exactly where you left them.
        </p>
      </div>

      <div :if={not @editing_cap} class="flex flex-wrap gap-1.5">
        <Kit.btn size={:sm} type="button" phx-click="edit_cap">Change the limit</Kit.btn>
      </div>

      <form :if={@editing_cap} id="cap-form" phx-submit="save_cap">
        <div class="lbl dim mb-1.5">Your daily limit</div>
        <div class="flex gap-1.5">
          <label for="cap-input" class="sr-only">Your daily limit</label>
          <input
            id="cap-input"
            type="text"
            name="cap"
            inputmode="decimal"
            value={money_value(@cap)}
            class="field px-3 py-2 text-[14px] mono flex-1"
          />
          <Kit.btn kind={:primary} size={:sm} type="submit">Save</Kit.btn>
        </div>
      </form>

      <%!-- Per-campaign spend has never been shown anywhere. Each row links to that
            campaign's own limit, which is where you'd change it. --%>
      <div :if={@spend_rows != []} class="mt-3">
        <div class="lbl dim mb-1.5">Where it went</div>
        <Kit.sheet>
          <div
            :for={r <- @spend_rows}
            class="px-3.5 py-2.5 row flex items-center justify-between gap-2"
          >
            <div class="min-w-0">
              <.link :if={r.id} navigate={~p"/campaigns/#{r.id}"} class="text-[13px] font-semibold ttl">
                <%= r.name %>
              </.link>
              <div :if={is_nil(r.id)} class="text-[13px] font-semibold"><%= r.name %></div>
              <div class="text-[11px] dim"><%= r.detail %></div>
            </div>
            <span class="mono text-[13px] shrink-0"><%= money(r.amount) %></span>
          </div>
        </Kit.sheet>
      </div>
    </Kit.row>
    """
  end

  # ── You ──────────────────────────────────────────────────────────────────────

  defp you(assigns) do
    ~H"""
    <Kit.row class="px-4 py-3">
      <div class="lbl dim mb-2">You</div>
      <Kit.sheet>
        <div class="px-3.5 py-2.5 row">
          <form id="username-form" phx-submit="username">
            <label for="username-input" class="text-[13px] font-semibold">What people see</label>
            <div class="flex gap-1.5 mt-1.5">
              <input
                id="username-input"
                type="text"
                name="username"
                value={@current_user.username}
                class="field px-3 py-2 text-[14px] flex-1"
              />
              <Kit.btn size={:sm} type="submit" disabled={@username_free_in != nil}>Save</Kit.btn>
            </div>
          </form>
          <div class="flex items-start gap-1.5 mt-1.5">
            <Kit.dot colour="var(--bcm)" class="mt-1.5 shrink-0" />
            <span class="text-[11.5px] leading-relaxed dim"><%= username_note(@username_free_in) %></span>
          </div>
        </div>

        <div class="px-3.5 py-2.5 row flex items-center justify-between gap-2">
          <div>
            <div class="text-[13px] font-semibold">Email</div>
            <div class="text-[11px] dim"><%= @current_user.email %></div>
          </div>
        </div>

        <%!-- Eligibility, not a content setting: everyone here has confirmed it, which
              is what having an account means, so there's nothing to change. --%>
        <div class="px-3.5 py-2.5 flex items-center justify-between gap-2">
          <div>
            <div class="text-[13px] font-semibold">Age</div>
            <div class="text-[11px] dim">Confirmed 18 or over</div>
          </div>
          <Kit.pill class="shrink-0">Locked</Kit.pill>
        </div>
      </Kit.sheet>
    </Kit.row>
    """
  end

  # ── Data ─────────────────────────────────────────────────────────────────────

  # §B4's preferences, which existed as rows nobody could reach. Opt-*out*: a row is
  # written only when somebody turns something off, so the absence of a row is consent
  # rather than a gap, and a new notification type doesn't need a backfill.
  #
  # `magic_link` is deliberately absent from the list. It is the only way into the
  # account, and a switch that can lock you out of your own sign-in is not a
  # preference — `Notifications` forces it past prefs for the same reason.
  defp notifications_section(assigns) do
    ~H"""
    <div class="px-4 py-3">
      <div class="lbl dim mb-2">Email</div>
      <Kit.sheet>
        <label
          :for={{type, label, note} <- notification_types()}
          class="px-3.5 py-2.5 row last:border-b-0 flex items-center justify-between gap-3 cursor-pointer"
        >
          <span>
            <span class="text-[13px] font-semibold block"><%= label %></span>
            <span class="text-[11px] leading-relaxed dim"><%= note %></span>
          </span>
          <input
            type="checkbox"
            class="sr-only"
            phx-click="toggle_notification"
            phx-value-type={type}
          />
          <Kit.sw on={@notifications[type]} />
        </label>
      </Kit.sheet>
      <p class="text-[11px] leading-relaxed dim mt-1.5">
        Sign-in links always arrive — they are the way back in, not a subscription.
      </p>
    </div>
    """
  end

  # Ordered by how much a person would miss it. Everything the system can send, minus
  # the one that isn't optional.
  defp notification_prefs(user) do
    Map.new(notification_types(), fn {type, _label, _note} ->
      {type, Prefs.wants?(user.id, type)}
    end)
  end

  defp notification_types do
    [
      {"report_alert", "Something you moderate", "A report lands on a campaign you run."},
      {"owner_warning", "A warning about your account", "Rare, and worth reading."},
      {"comment_reply", "Replies to you", "When someone answers something you wrote."},
      {"subscription", "Campaigns you follow", "New chapters in something you're reading."}
    ]
  end

  defp data_section(assigns) do
    ~H"""
    <div class="px-4 py-3">
      <div class="lbl dim mb-2">Data</div>
      <Kit.sheet>
        <div class="px-3.5 py-2.5 row flex items-center justify-between gap-3">
          <div>
            <div class="text-[13px] font-semibold">Take everything with you</div>
            <div class="text-[11px] leading-relaxed dim mt-0.5">
              Every campaign, world, character and transcript, as files.
            </div>
          </div>
          <.link navigate={~p"/library"} class="btn btn-gh btn-sm shrink-0">Export</.link>
        </div>
        <div :if={is_nil(@days_until_deletion)} class="px-3.5 py-2.5">
          <Kit.btn kind={:pen} size={:sm} type="button" phx-click="confirm_delete" class="-ml-1">
            Delete my account
          </Kit.btn>
          <p class="text-[11px] leading-relaxed dim mt-1">
            Everything goes, after <%= Accounts.deletion_window_days() %> days. Published
            copies are removed too.
          </p>
        </div>
      </Kit.sheet>
    </div>
    """
  end

  defp delete_confirm(assigns) do
    ~H"""
    <Kit.sheet class="m-4 p-4">
      <div class="ttl text-[15px] font-semibold mb-1.5">Delete your account?</div>
      <p class="text-[13px] leading-relaxed dim mb-2.5"><%= what_goes(assigns) %></p>
      <div class="rounded-lg p-2.5 mb-3" style="background:var(--b3)">
        <p class="text-[12px] leading-relaxed">
          Anyone who forked something of yours keeps their copy — it's theirs now. Your
          original goes.
        </p>
      </div>
      <p class="text-[12.5px] leading-relaxed dim mb-2.5">
        Sign back in within <%= Accounts.deletion_window_days() %> days and none of this
        happens.
      </p>
      <div class="flex gap-1.5">
        <Kit.btn kind={:pen} size={:sm} type="button" phx-click="delete_account">Delete it</Kit.btn>
        <Kit.btn size={:sm} type="button" phx-click="keep_it">Keep it</Kit.btn>
      </div>
    </Kit.sheet>
    """
  end

  # ── Copy ─────────────────────────────────────────────────────────────────────

  # Counted rather than described, because "all your work" is easy to skim past and
  # "three campaigns, two worlds and forty-one characters" isn't.
  defp what_goes(assigns) do
    entries = Library.list_for_owner(Owner.of(assigns.current_user))
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

  defp leaving_line(0), do: "Your account goes today"
  defp leaving_line(1), do: "Your account goes tomorrow"
  defp leaving_line(n), do: "Your account goes in #{n} days"

  defp turns_line(1), do: "About one more turn at what today has cost."
  defp turns_line(n), do: "About #{n} more turns at what today has cost."

  defp username_note(nil), do: "You can change this once a month."
  defp username_note(1), do: "You can change this once a month. Next change available tomorrow."

  defp username_note(n),
    do: "You can change this once a month. Next change available in #{n} days."

  # Spent reads as spent, not as more amber: the bar changes meaning at the ceiling and
  # the mock changes its colour to say so.
  defp bar_colour(f) when f >= 1.0, do: "var(--pencil)"
  defp bar_colour(_), do: nil

  defp spend_colour(f) when f >= 1.0, do: "color:var(--pencil)"
  defp spend_colour(f) when f >= 0.8, do: "color:var(--lamp)"
  defp spend_colour(_), do: nil

  # The ledger counts micro-cents; people count pounds and pence. The conversion lives
  # here, at the edge, so nothing in the domain has to know about currency.
  @per_unit 100_000

  defp money(amount) when is_integer(amount) do
    "$" <> :erlang.float_to_binary(amount / @per_unit, decimals: 2)
  end

  defp money(_), do: "$0.00"

  defp money_value(amount) when is_integer(amount),
    do: :erlang.float_to_binary(amount / @per_unit, decimals: 2)

  defp money_value(_), do: "0.00"

  defp parse_money(raw) do
    case raw
         |> to_string()
         |> String.trim()
         |> String.replace(~r/[^0-9.]/, "")
         |> Float.parse() do
      {value, _} when value > 0 -> round(value * @per_unit)
      _ -> nil
    end
  end
end
