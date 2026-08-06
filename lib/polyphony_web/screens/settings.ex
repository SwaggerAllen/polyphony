defmodule PolyphonyWeb.Screens.Settings do
  @moduledoc """
  Account settings, as markup.

  Two things here are load-bearing rather than decorative. A **cap you can actually
  change** — the error copy promised *you can raise it in Settings* long before anything
  behind it existed — and spend shown as **turns remaining rather than a percentage**,
  because nobody knows what 86% of their budget feels like. It returns nil rather than
  guessing when there is no history, since a made-up number is worse than an absent one.

  It reads nothing: the library count behind the delete confirmation and the notification
  preferences are both queries, so the LiveView runs them and passes the answers in.
  """
  use PolyphonyWeb, :html

  alias Polyphony.Accounts
  alias Polyphony.Accounts.User
  alias PolyphonyWeb.{Kit, Layouts}

  # "" in the app; a distinct prefix per storybook variation, which all render together.
  defp eid("", name), do: name
  defp eid(nil, name), do: name
  defp eid(prefix, name), do: "#{prefix}-#{name}"

  attr(:id, :string, default: "", doc: "prefix for every element id — see eid/2")

  attr(:current_user, :map, required: true)
  attr(:needs_reconsent, :boolean, default: false)

  attr(:username_free_in, :any,
    default: nil,
    doc: "days until the handle can change again, or nil"
  )

  attr(:cap, :any,
    default: nil,
    doc: "this account's daily cap — stored → opts → config → default"
  )

  attr(:editing_cap, :boolean, default: false)
  attr(:spent_today, :any, default: nil)
  attr(:this_month, :any, default: nil)
  attr(:fraction, :any, default: nil)

  attr(:turns_left, :any,
    default: nil,
    doc: "nil rather than a guess when there is no history to estimate from"
  )

  attr(:spend_rows, :list,
    default: [],
    doc: "per-campaign breakdown; scene generations attribute to their campaign"
  )

  attr(:notifications, :map, default: %{}, doc: "type => wants?, answered by the LiveView")

  attr(:what_goes, :string,
    default: "",
    doc: "the counted library, so 'all your work' is not skimmed past"
  )

  attr(:confirming_delete, :boolean, default: false)
  attr(:days_until_deletion, :any, default: nil)

  def screen(assigns) do
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

      <form :if={@editing_cap} id={eid(@id, "cap-form")} phx-submit="save_cap">
        <div class="lbl dim mb-1.5">Your daily limit</div>
        <div class="flex gap-1.5">
          <label for={eid(@id, "cap-input")} class="sr-only">Your daily limit</label>
          <input
            id={eid(@id, "cap-input")}
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
          <form id={eid(@id, "username-form")} phx-submit="username">
            <label for={eid(@id, "username-input")} class="text-[13px] font-semibold">What people see</label>
            <div class="flex gap-1.5 mt-1.5">
              <input
                id={eid(@id, "username-input")}
                type="text"
                name="username"
                value={@current_user.username}
                pattern={User.username_pattern()}
                title={User.username_rule()}
                aria-describedby={eid(@id, "username-rule")}
                class="field px-3 py-2 text-[14px] flex-1"
              />
              <Kit.btn size={:sm} type="submit" disabled={@username_free_in != nil}>Save</Kit.btn>
            </div>
          </form>
          <%!-- The rule, stated where it can be read rather than where it is broken.
                Same sentence as the sign-up form, from `User.username_rule/0`, because
                two forms writing it separately is two forms that will disagree. --%>
          <p id={eid(@id, "username-rule")} class="text-[11px] leading-relaxed dim mt-1.5">
            <%= User.username_rule() %>
          </p>
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

  @doc """
  Everything the system can send, minus the one that isn't optional, ordered by how much
  a person would miss it. Public because the LiveView reads the same list to ask `Prefs`
  which of them this account wants — the labels are display and belong here, the answer
  is a query and belongs there.
  """
  def notification_types do
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
      <p class="text-[13px] leading-relaxed dim mb-2.5"><%= @what_goes %></p>
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

  def money(amount) when is_integer(amount) do
    "$" <> :erlang.float_to_binary(amount / @per_unit, decimals: 2)
  end

  def money(_), do: "$0.00"

  defp money_value(amount) when is_integer(amount),
    do: :erlang.float_to_binary(amount / @per_unit, decimals: 2)

  defp money_value(_), do: "0.00"

  def parse_money(raw) do
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
