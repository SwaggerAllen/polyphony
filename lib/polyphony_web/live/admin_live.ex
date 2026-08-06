defmodule PolyphonyWeb.AdminLive do
  @moduledoc """
  Moderation, ported from `ux/polyphony-admin.html`.

  An internal tool for people making judgement calls under time pressure, which means
  **density is fine and ambiguity isn't**. Four things it has to get right:

  ## Child safety is its own lane

  Not a filter on a general queue — a separate list that is always first, always
  visible, and doesn't get buried under forty spam reports. Different urgency,
  different handling. Within a lane it's oldest first, because the alternative is
  reports that never get looked at.

  ## Reading a report means bypassing publication scope

  A moderator has to see everything to judge, including perspectives the author never
  shared. That is a real privilege, so the screen **says so out loud** and asks why
  before granting it — a reason field turns an unlogged habit into a decision, and
  nobody types a reason forty times a day for something they don't need. It's audited
  with their name on it (§C).

  ## Content and people are different objects

  Taking down a snapshot and suspending an account have different consequences and
  different reversals. Never one button, never the same row.

  ## A take-down takes everything, and spreads

  The public copy and the author's own, plus every fork descended from it — which
  can't be deleted blind, because a fork may have diverged past anything
  objectionable. So it opens a **review lane** rather than firing a cascade.

  Demotion and reinstatement were built in the domain and never reachable, so an admin
  promoted by mistake was permanent and a suspension was one-way. Both have buttons now.
  """
  use PolyphonyWeb, :live_view

  alias Polyphony.{Accounts, Library, Moderation}
  alias Polyphony.Moderation.Report
  alias PolyphonyWeb.{Kit, Layouts, Voice}

  @tabs ~w(waiting decided suspended invites admins)

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Moderation", open: nil, unlocking: nil, viewed: nil)
     |> load()}
  end

  def handle_params(params, _uri, socket) do
    tab = if params["tab"] in @tabs, do: params["tab"], else: "waiting"
    {:noreply, socket |> assign(tab: tab) |> assign_open(params["report"])}
  end

  defp assign_open(socket, nil), do: assign(socket, open: nil, unlocking: nil, viewed: nil)

  defp assign_open(socket, id) do
    case Moderation.get_report(to_int(id)) do
      nil -> assign(socket, open: nil, unlocking: nil, viewed: nil)
      report -> assign(socket, open: decorate(report))
    end
  end

  defp load(socket) do
    lanes = Moderation.lanes()

    assign(socket,
      lanes: lanes,
      decided: Moderation.list_resolved(),
      suspended: Enum.map(Accounts.list_suspended(), &suspended_row/1),
      admins: Accounts.list_admins(),
      audit: Moderation.recent_audit(limit: 20),
      invites: Accounts.list_invites()
    )
  end

  # Enough context to decide, in one read: who it's about, what the reporter said, and
  # both directions of the account's history — because someone whose own reports are
  # nearly all dismissed is a signal too.
  defp decorate(report) do
    %{
      id: report.id,
      report: report,
      reason: report.reason,
      detail: report.detail,
      owner: report.owner_id && Accounts.get(report.owner_id),
      reporter: report.reporter_id && Accounts.get(report.reporter_id),
      history: report.owner_id && Moderation.history(report.owner_id),
      dismissals: Moderation.previous_dismissals(report),
      item: report.item_type == "library_entry" && Library.get(report.item_id),
      urgent?: Report.absolute_line?(report.reason)
    }
  end

  defp suspended_row(user) do
    %{
      user: user,
      days_left: Accounts.suspension_days_left(user),
      hidden: Enum.count(Library.hidden(), &(to_string(&1.owner_id) == to_string(user.id)))
    }
  end

  # ── Events ───────────────────────────────────────────────────────────────────

  # Opening what wasn't published is asked for, not taken.
  def handle_event("ask_unlock", _params, socket),
    do: {:noreply, assign(socket, unlocking: true)}

  def handle_event("cancel_unlock", _params, socket),
    do: {:noreply, assign(socket, unlocking: nil)}

  def handle_event("unlock", %{"why" => why}, socket) do
    safe(socket, fn ->
      case Moderation.access_report_content(
             socket.assigns.current_user,
             socket.assigns.open.report,
             why: why
           ) do
        {:ok, entries} ->
          {:noreply,
           socket
           |> assign(unlocking: nil, viewed: entries)
           |> put_flash(:info, "Reading as the author. It's written down.")
           |> load()}

        _ ->
          {:noreply, put_flash(socket, :error, "Could not open it.")}
      end
    end)
  end

  def handle_event("dismiss", _params, socket),
    do: resolve(socket, &Moderation.dismiss(&1, &2), "Left up.")

  def handle_event("warn", %{"message" => message}, socket),
    do: resolve(socket, &Moderation.warn_owner(&1, &2, message), "Sent.")

  def handle_event("take_down", _params, socket),
    do:
      resolve(
        socket,
        &Moderation.take_down(&1, &2, "reported and upheld"),
        "Taken down. Its forks are in review."
      )

  def handle_event("suspend", params, socket) do
    days = params["days"] |> to_string() |> to_int()
    resolve(socket, &Moderation.suspend_user(&1, &2, days), "Suspended.")
  end

  def handle_event("leave_fork", %{"id" => id}, socket) do
    safe(socket, fn ->
      Moderation.leave_fork(socket.assigns.current_user, to_int(id))
      {:noreply, socket |> put_flash(:info, "Left up.") |> load()}
    end)
  end

  def handle_event("take_down_fork", %{"id" => id}, socket) do
    safe(socket, fn ->
      Moderation.take_down_fork(socket.assigns.current_user, to_int(id), "carries the same")
      {:noreply, socket |> put_flash(:info, "Taken down too.") |> load()}
    end)
  end

  def handle_event("lift", %{"id" => id}, socket) do
    safe(socket, fn ->
      case Accounts.get(to_int(id)) do
        nil ->
          {:noreply, socket}

        user ->
          Moderation.lift_suspension(socket.assigns.current_user, user)
          {:noreply, socket |> put_flash(:info, "Lifted.") |> load()}
      end
    end)
  end

  def handle_event("mint_invite", _params, socket), do: mint(socket, [])

  # Stays valid after it is used — for putting a second and third account on a build
  # while testing by hand, which single-use turns into a trip back here each time.
  def handle_event("mint_reusable", _params, socket), do: mint(socket, reusable: true)

  def handle_event("revoke_invite", %{"id" => id}, socket) do
    safe(socket, fn ->
      case Accounts.revoke_invite(socket.assigns.current_user, to_int(id)) do
        {:ok, _} -> {:noreply, socket |> put_flash(:info, "Closed it.") |> load()}
        _ -> {:noreply, put_flash(socket, :error, "Couldn't close it.")}
      end
    end)
  end

  # Demotion has never existed, so an admin made by mistake was permanent.
  def handle_event("demote", %{"id" => id}, socket) do
    safe(socket, fn ->
      with %{} = target <- Accounts.get(to_int(id)),
           {:ok, _} <- Accounts.demote_to_user(socket.assigns.current_user, target) do
        {:noreply, socket |> put_flash(:info, "Made ordinary.") |> load()}
      else
        _ -> {:noreply, put_flash(socket, :error, "Can't change that one.")}
      end
    end)
  end

  def handle_event("promote", %{"username" => username}, socket) do
    safe(socket, fn ->
      with %{} = target <- Accounts.get_by_username(String.trim(to_string(username))),
           {:ok, _} <- Accounts.promote_to_admin(socket.assigns.current_user, target) do
        {:noreply, socket |> put_flash(:info, "They're an admin now.") |> load()}
      else
        _ -> {:noreply, put_flash(socket, :error, "Couldn't promote them.")}
      end
    end)
  end

  defp resolve(socket, fun, message) do
    safe(socket, fn ->
      case fun.(socket.assigns.current_user, socket.assigns.open.report) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, message)
           |> load()
           |> push_patch(to: ~p"/admin?#{[tab: "waiting"]}")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Couldn't do that: #{inspect(reason)}")}
      end
    end)
  end

  # ── Render ───────────────────────────────────────────────────────────────────

  def render(assigns) do
    ~H"""
    <Kit.frame class="flex flex-col min-h-[100dvh]">
      <Kit.header title="Moderation" subtitle={waiting_line(assigns)}>
        <:actions>
          <Kit.pill><%= @current_user.username %></Kit.pill>
          <Layouts.nav_menu current_user={@current_user} />
        </:actions>
      </Kit.header>

      <Kit.tabs>
        <:tab patch={~p"/admin?#{[tab: "waiting"]}"} on={@tab == "waiting"}>
          Waiting <span class="dim"><%= waiting_count(assigns) %></span>
        </:tab>
        <:tab patch={~p"/admin?#{[tab: "decided"]}"} on={@tab == "decided"}>Decided</:tab>
        <:tab patch={~p"/admin?#{[tab: "suspended"]}"} on={@tab == "suspended"}>Suspended</:tab>
        <:tab patch={~p"/admin?#{[tab: "invites"]}"} on={@tab == "invites"}>Invites</:tab>
        <:tab patch={~p"/admin?#{[tab: "admins"]}"} on={@tab == "admins"}>Admins</:tab>
      </Kit.tabs>

      <div class="flex-1 min-h-0 overflow-y-auto">
        <.one_report :if={@open} {assigns} />
        <.queue :if={is_nil(@open) and @tab == "waiting"} {assigns} />
        <.decided :if={is_nil(@open) and @tab == "decided"} {assigns} />
        <.suspended :if={is_nil(@open) and @tab == "suspended"} {assigns} />
        <.invites :if={is_nil(@open) and @tab == "invites"} {assigns} />
        <.admins :if={is_nil(@open) and @tab == "admins"} {assigns} />
      </div>
    </Kit.frame>
    """
  end

  # ── The queue ────────────────────────────────────────────────────────────────

  defp queue(assigns) do
    ~H"""
    <Kit.sheet class="m-4">
      <%!-- Its own lane, always first, never buried under forty spam reports. --%>
      <Kit.row :if={@lanes.urgent != []} class="px-4 py-2.5 urgent">
        <div class="flex items-center justify-between gap-2">
          <span class="text-[12.5px] font-semibold" style="color:var(--pencil)">
            Child safety · <%= length(@lanes.urgent) %>
          </span>
          <span class="mono text-[10px]" style="color:var(--pencil)">
            oldest <%= age(List.first(@lanes.urgent)) %>
          </span>
        </div>
      </Kit.row>
      <.report_row :for={r <- @lanes.urgent} report={r} urgent={true} />

      <%!-- A take-down spreads, and can't spread blind: a fork may have diverged
            twenty scenes past anything objectionable. --%>
      <Kit.row :if={@lanes.forks != []} class="px-4 py-2.5" style="background:var(--b2)">
        <span class="lbl dim">Forks of things taken down · <%= length(@lanes.forks) %></span>
      </Kit.row>
      <Kit.row :for={f <- @lanes.forks} class="px-4 py-3">
        <div class="flex items-center justify-between gap-2 mb-1">
          <div class="ttl text-[14.5px] min-w-0 truncate font-semibold">
            <%= entry_name(f.entry) %>
          </div>
          <span class="mono text-[10px] dim shrink-0">fork</span>
        </div>
        <div class="lbl dim mb-1.5"><%= fork_line(f) %></div>
        <p class="text-[13px] leading-relaxed dim">
          It may contain none of what was reported. Somebody has to look.
        </p>
        <div class="flex gap-1.5 mt-2">
          <Kit.btn size={:sm} type="button" phx-click="leave_fork" phx-value-id={f.entry.id}>
            Leave it
          </Kit.btn>
          <Kit.btn
            kind={:pen}
            size={:sm}
            type="button"
            phx-click="take_down_fork"
            phx-value-id={f.entry.id}
            data-confirm="Take this fork down too?"
          >
            Take it down
          </Kit.btn>
        </div>
      </Kit.row>

      <Kit.row :if={@lanes.rest != []} class="px-4 py-2.5" style="background:var(--b2)">
        <span class="lbl dim">Everything else · <%= length(@lanes.rest) %></span>
      </Kit.row>
      <.report_row :for={r <- @lanes.rest} report={r} urgent={false} />

      <Kit.empty :if={waiting_count(assigns) == 0} headline="Nothing waiting." class="py-9">
        Reports arrive here as they're made — child safety first, and oldest first inside
        each lane.
      </Kit.empty>
    </Kit.sheet>
    """
  end

  attr(:report, :map, required: true)
  attr(:urgent, :boolean, required: true)

  defp report_row(assigns) do
    ~H"""
    <Kit.row class={if @urgent, do: "px-4 py-3 urgent", else: "px-4 py-3"}>
      <div class="flex items-center justify-between gap-2 mb-1">
        <.link
          patch={~p"/admin?#{[report: @report.id]}"}
          class="ttl text-[14.5px] min-w-0 truncate font-semibold"
        >
          <%= subject_name(@report) %>
        </.link>
        <span class="mono text-[10px] dim shrink-0">#<%= @report.id %></span>
      </div>
      <div class="lbl dim mb-1.5"><%= by_line(@report) %></div>
      <p class={["text-[13px] leading-relaxed", not @urgent && "dim"]}>
        <%= reason_label(@report.reason) %><%= detail_suffix(@report) %>
      </p>
      <div :if={@urgent} class="flex gap-1.5 mt-2">
        <.link patch={~p"/admin?#{[report: @report.id]}"} class="btn btn-pri btn-sm">
          Look at it
        </.link>
      </div>
    </Kit.row>
    """
  end

  # ── One report ───────────────────────────────────────────────────────────────

  defp one_report(assigns) do
    ~H"""
    <Kit.sheet class="m-4">
      <Kit.row class="px-4 py-3" style="background:var(--b2)">
        <div class="flex items-center justify-between gap-2 mb-1">
          <span class="ttl text-[16px] font-semibold">Report #<%= @open.id %></span>
          <Kit.pill class="shrink-0"><%= age(@open.report) %> old</Kit.pill>
        </div>
        <div class="lbl dim"><%= reason_label(@open.reason) %></div>
      </Kit.row>

      <Kit.row :if={@open.detail} class="px-4 py-3">
        <div class="lbl dim mb-1.5">What they said</div>
        <p class="text-[13px] leading-relaxed"><%= @open.detail %></p>
        <div :if={@open.reporter} class="text-[11px] dim mt-1.5">
          From <b style="color:var(--bc)"><%= @open.reporter.username %></b>
        </div>
      </Kit.row>

      <Kit.row :if={@open.item} class="px-4 py-3">
        <div class="lbl dim mb-1.5">What was reported</div>
        <div class="urgent px-2.5 py-2 rounded-r-lg">
          <p class="text-[13px] leading-relaxed"><%= entry_name(@open.item) %></p>
          <div class="text-[11px] dim mt-1"><%= item_line(@open.item) %></div>
        </div>
      </Kit.row>

      <%!-- The fourth report on the same thing usually means somebody's campaigning
            rather than reporting. --%>
      <Kit.row :if={@open.dismissals > 0} class="px-4 py-3">
        <div class="flex items-center gap-1.5">
          <Kit.dot colour="var(--bcm)" />
          <span class="text-[12px] dim"><%= dismissals_line(@open.dismissals) %></span>
        </div>
      </Kit.row>

      <.history_block :if={@open.owner} {assigns} />

      <%!-- A real privilege, said out loud rather than granted silently. --%>
      <Kit.row :if={@unlocking} class="px-4 py-3" style="background:var(--b2)">
        <div class="ttl text-[15px] font-semibold mb-1.5">See the whole thing?</div>
        <p class="text-[13px] leading-relaxed mb-2.5">
          Opening it as the author means seeing private thoughts, whispers and character
          sheets they chose not to share.
        </p>
        <p class="text-[13px] leading-relaxed dim mb-2.5">
          That's yours to do when a report needs it. It gets written down, with your name.
        </p>
        <form id="unlock-form" phx-submit="unlock">
          <label for="unlock-why" class="lbl dim mb-1.5 block">Why you need it</label>
          <textarea
            id="unlock-why"
            name="why"
            rows="2"
            required
            placeholder="The reported passage doesn't make sense without what's around it…"
            class="field px-3 py-2.5 text-[13px] leading-relaxed w-full mb-2.5"
          ></textarea>
          <div class="flex gap-1.5">
            <Kit.btn kind={:primary} size={:sm} type="submit">Open it</Kit.btn>
            <Kit.btn size={:sm} type="button" phx-click="cancel_unlock">Cancel</Kit.btn>
          </div>
        </form>
      </Kit.row>

      <Kit.row
        :if={@viewed}
        class="px-4 py-2"
        style="background:color-mix(in srgb,var(--pencil) 12%,transparent)"
      >
        <span class="text-[12.5px]">Reading as the author · logged</span>
      </Kit.row>
      <Kit.row :for={e <- @viewed || []} class="px-4 py-2.5">
        <div class="text-[13px] font-semibold"><%= entry_name(e) %></div>
        <div class="text-[11px] dim"><%= item_line(e) %></div>
      </Kit.row>

      <div class="px-4 py-3">
        <div class="flex flex-wrap gap-1.5 mb-3">
          <Kit.btn
            :if={is_nil(@viewed) and is_nil(@unlocking)}
            size={:sm}
            type="button"
            phx-click="ask_unlock"
          >
            See what wasn't published
          </Kit.btn>
          <.link patch={~p"/admin?#{[tab: "waiting"]}"} class="btn btn-gh btn-sm">
            Back to the queue
          </.link>
        </div>

        <%!-- Content and people never share a row: different consequences, different
              reversals. --%>
        <div class="lbl dim mb-1.5">The content</div>
        <div class="flex flex-wrap gap-1.5 mb-3">
          <Kit.btn kind={:primary} size={:sm} type="button" phx-click="dismiss">
            Leave it up
          </Kit.btn>
          <Kit.btn
            kind={:red}
            size={:sm}
            type="button"
            phx-click="take_down"
            data-confirm={takedown_confirm(assigns)}
          >
            Take it down
          </Kit.btn>
        </div>

        <form id="warn-form" phx-submit="warn" class="mb-3">
          <label for="warn-message" class="lbl dim mb-1.5 block">Or a word about it</label>
          <textarea
            id="warn-message"
            name="message"
            rows="2"
            required
            placeholder="What they need to know…"
            class="field px-3 py-2.5 text-[13px] leading-relaxed w-full mb-1.5"
          ></textarea>
          <Kit.btn size={:sm} type="submit">Send it</Kit.btn>
        </form>

        <div :if={@open.owner}>
          <div class="lbl dim mb-1.5">The person</div>
          <div class="rounded-lg p-2.5 mb-2" style="background:var(--b3)">
            <p class="text-[12px] leading-relaxed mb-1">
              They can't sign in or publish. Nothing of theirs is deleted.
            </p>
            <p class="text-[12px] leading-relaxed">
              <b>Everything they've shared goes dark</b>
              — public and unlisted both, so share links stop working too.
            </p>
          </div>
          <div class="flex flex-wrap gap-1.5">
            <Kit.btn
              :for={{label, days} <- suspension_lengths()}
              kind={:pen}
              size={:sm}
              type="button"
              phx-click="suspend"
              phx-value-days={days}
              data-confirm={"Suspend #{@open.owner.username}? #{String.downcase(label)}."}
            >
              <%= label %>
            </Kit.btn>
          </div>
        </div>
      </div>
    </Kit.sheet>
    """
  end

  # Both directions: someone whose own reports are nearly all dismissed is a signal
  # too, and a queue that only looks at the accused can't see that.
  defp history_block(assigns) do
    ~H"""
    <Kit.row class="px-4 py-3">
      <div class="lbl dim mb-2"><%= @open.owner.username %>'s history</div>
      <div class="flex flex-wrap gap-1.5 mb-2.5">
        <Kit.pill colour={prior_count(@open) > 0 && "var(--lamp)"}>
          <%= count(prior_count(@open), "other against them", "others against them") %>
        </Kit.pill>
        <Kit.pill :if={@open.history.against_upheld > 0}>
          <%= @open.history.against_upheld %> upheld
        </Kit.pill>
        <Kit.pill :if={@open.history.made != []}>
          <%= count(length(@open.history.made), "made by them", "made by them") %>
        </Kit.pill>
        <Kit.pill :if={@open.history.made != []}>
          <%= @open.history.made_dismissed %> of those dismissed
        </Kit.pill>
      </div>
      <div class="flex flex-col gap-1">
        <%!-- The report you're looking at isn't its own history. --%>
        <div
          :for={r <- @open.history.against |> Enum.reject(&(&1.id == @open.id)) |> Enum.take(4)}
          class="flex items-center gap-2"
        >
          <Kit.dot colour={outcome_colour(r)} class="shrink-0" />
          <span class="text-[12px] flex-1"><%= outcome_label(r) %></span>
          <span class="text-[11px] dim shrink-0"><%= month(r.inserted_at) %></span>
        </div>
      </div>
    </Kit.row>
    """
  end

  # ── The other tabs ───────────────────────────────────────────────────────────

  defp decided(assigns) do
    ~H"""
    <div class="m-4 flex flex-col gap-4">
      <Kit.sheet>
        <Kit.row class="px-4 py-3" style="background:var(--b2)">
          <span class="ttl text-[15px] font-semibold">Decided</span>
        </Kit.row>
        <Kit.row :for={r <- @decided} class="px-4 py-2.5">
          <div class="flex items-center justify-between gap-2 mb-0.5">
            <span class="text-[12.5px] font-semibold"><%= outcome_label(r) %></span>
            <span class="mono text-[10px] dim shrink-0">#<%= r.id %></span>
          </div>
          <div class="text-[11px] dim"><%= reason_label(r.reason) %></div>
        </Kit.row>
        <Kit.empty :if={@decided == []} headline="Nothing decided yet." class="py-7" />
      </Kit.sheet>

      <%!-- Privilege use is tinted: the entry most likely to matter later and the
            least likely to be looked for. --%>
      <Kit.sheet>
        <Kit.row class="px-4 py-3" style="background:var(--b2)">
          <span class="ttl text-[15px] font-semibold">What's been done</span>
        </Kit.row>
        <Kit.row
          :for={a <- @audit}
          class="px-4 py-2.5"
          style={
            a.action == "content_access" &&
              "background:color-mix(in srgb,var(--pencil) 6%,transparent)"
          }
        >
          <div class="flex items-center justify-between gap-2 mb-0.5">
            <span class="text-[12.5px] font-semibold"><%= audit_label(a.action) %></span>
            <span class="mono text-[10px] dim shrink-0"><%= time_of(a.inserted_at) %></span>
          </div>
          <div class="text-[11px] dim"><%= audit_detail(a) %></div>
        </Kit.row>
        <Kit.empty :if={@audit == []} headline="Nothing done yet." class="py-7" />
      </Kit.sheet>
    </div>
    """
  end

  defp suspended(assigns) do
    ~H"""
    <Kit.sheet class="m-4">
      <Kit.row class="px-4 py-3" style="background:var(--b2)">
        <span class="ttl text-[15px] font-semibold">Suspended</span>
      </Kit.row>
      <Kit.row :for={s <- @suspended} class="px-4 py-2.5">
        <div class="flex items-center gap-2.5 mb-1.5">
          <span class="av" style="background:var(--b3)"></span>
          <div class="min-w-0 flex-1">
            <div class="text-[13px] font-semibold"><%= s.user.username %></div>
            <div class="text-[11px]" style={is_nil(s.days_left) && "color:var(--pencil)"}>
              <%= suspension_line(s.days_left) %>
            </div>
          </div>
        </div>
        <div class="text-[11px] dim mb-1.5"><%= hidden_line(s.hidden) %></div>
        <%!-- An indefinite suspension with no way back is a deletion nobody agreed to. --%>
        <Kit.btn size={:sm} type="button" phx-click="lift" phx-value-id={s.user.id}>Lift it</Kit.btn>
      </Kit.row>
      <Kit.empty :if={@suspended == []} headline="Nobody is suspended." class="py-7" />
    </Kit.sheet>
    """
  end

  defp invites(assigns) do
    ~H"""
    <Kit.sheet class="m-4">
      <Kit.row class="px-4 py-3 flex items-center justify-between gap-2" style="background:var(--b2)">
        <span class="ttl text-[15px] font-semibold">Invites</span>
        <div class="flex gap-1.5">
          <%!-- Two buttons rather than a switch beside one, because these are different
                objects once minted and the difference is not a setting you'd revisit.
                The reusable one is a standing hole in the gate for as long as it exists
                — so it says what it is on the row, and it can be closed. --%>
          <Kit.btn size={:sm} type="button" phx-click="mint_reusable">Reusable</Kit.btn>
          <Kit.btn kind={:primary} size={:sm} type="button" phx-click="mint_invite">Mint one</Kit.btn>
        </div>
      </Kit.row>
      <Kit.row :for={i <- @invites} class="px-4 py-2.5 flex items-start justify-between gap-2">
        <div class="min-w-0">
          <div class={["mono text-[12px] break-all", spent?(i) && "dim"]} id={"invite-#{i.id}"}>
            <%= i.token %>
          </div>
          <div class="text-[11px] dim"><%= invite_line(i) %></div>
        </div>
        <div class="flex items-center gap-1 shrink-0">
          <%!-- The code is meant to be typed into another device, which is the whole
                use for a reusable one. Reading it off a phone screen is not that. --%>
          <Kit.btn
            kind={:ghost}
            size={:sm}
            type="button"
            id={"invite-copy-#{i.id}"}
            phx-hook="CopyText"
            data-copy-target={"invite-#{i.id}"}
          >
            Copy
          </Kit.btn>
          <Kit.btn :if={not spent?(i)} kind={:pen} type="button" phx-click="revoke_invite" phx-value-id={i.id}>
            Revoke
          </Kit.btn>
        </div>
      </Kit.row>
      <Kit.empty :if={@invites == []} headline="No invites minted." class="py-7">
        Polyphony is invite-only while it's young, so this is the door.
      </Kit.empty>
    </Kit.sheet>
    """
  end

  defp spent?(invite), do: Polyphony.Accounts.Invite.spent?(invite)

  defp admins(assigns) do
    ~H"""
    <Kit.sheet class="m-4">
      <Kit.row class="px-4 py-3" style="background:var(--b2)">
        <span class="ttl text-[15px] font-semibold">Admins</span>
      </Kit.row>
      <Kit.row :for={a <- @admins} class="px-4 py-2.5 flex items-center gap-2.5">
        <span class="av" style={"background:#{Voice.colour(rem(a.id, 8) + 1)}"}></span>
        <div class="min-w-0 flex-1">
          <div class="text-[13px] font-semibold"><%= a.username %></div>
          <div class="text-[11px] dim"><%= admin_line(a) %></div>
        </div>
        <%!-- The first account stays pinned: there is exactly one superadmin, minted at
              first sign-up and never assignable. --%>
        <Kit.pill :if={a.role == "superadmin"} class="shrink-0">Can't be changed</Kit.pill>
        <Kit.btn
          :if={a.role != "superadmin"}
          kind={:pen}
          size={:sm}
          type="button"
          phx-click="demote"
          phx-value-id={a.id}
          class="shrink-0"
        >
          Make ordinary
        </Kit.btn>
      </Kit.row>
      <div class="px-4 py-2.5">
        <form id="promote-form" phx-submit="promote" class="flex gap-1.5">
          <label for="promote-username" class="sr-only">Find someone to promote</label>
          <input
            id="promote-username"
            type="text"
            name="username"
            placeholder="Find someone to promote…"
            class="field px-3 py-2 text-[13px] flex-1"
          />
          <Kit.btn size={:sm} type="submit">Promote</Kit.btn>
        </form>
      </div>
    </Kit.sheet>
    """
  end

  # ── Copy ─────────────────────────────────────────────────────────────────────

  defp waiting_count(assigns),
    do: length(assigns.lanes.urgent) + length(assigns.lanes.forks) + length(assigns.lanes.rest)

  defp waiting_line(assigns) do
    case {length(assigns.lanes.urgent), waiting_count(assigns)} do
      {0, 0} -> "Nothing waiting"
      {0, n} -> count(n, "thing waiting", "things waiting")
      {u, n} -> "#{count(n, "thing waiting", "things waiting")} · #{u} on child safety"
    end
  end

  defp prior_count(open), do: Enum.count(open.history.against, &(&1.id != open.id))

  defp count(0, _one, many), do: "No #{many}"
  defp count(1, one, _many), do: "1 #{one}"
  defp count(n, _one, many), do: "#{n} #{many}"

  defp subject_name(report) do
    case report.item_type do
      "library_entry" ->
        case Library.get(report.item_id) do
          nil -> "Something that's gone"
          entry -> entry_name(entry)
        end

      _ ->
        "A person"
    end
  end

  defp by_line(report) do
    who =
      case report.owner_id && Accounts.get(report.owner_id) do
        nil -> nil
        owner -> "By #{owner.username}"
      end

    [who, "reported #{age(report)} ago"] |> Enum.filter(& &1) |> Enum.join(" · ")
  end

  defp detail_suffix(%{detail: d}) when is_binary(d) and d != "", do: " — \"#{d}\""
  defp detail_suffix(_), do: " — no detail given"

  defp reason_label("csam"), do: "Sexual content involving minors"
  defp reason_label("real_person_sexual"), do: "Sexual content about a real person"
  defp reason_label("harassment"), do: "Harassment of a real person"
  defp reason_label("nonconsensual_content"), do: "Content shared without consent"
  defp reason_label(_), do: "Breaks the rules another way"

  defp outcome_label(%{status: "dismissed"}), do: "Dismissed"
  defp outcome_label(%{resolution: "takedown"}), do: "Taken down"
  defp outcome_label(%{resolution: "suspend"}), do: "Suspended"
  defp outcome_label(%{status: "actioned"}), do: "Actioned"
  defp outcome_label(_), do: "Open"

  defp outcome_colour(%{status: "dismissed"}), do: "var(--bcm)"
  defp outcome_colour(%{resolution: "takedown"}), do: "var(--pencil)"
  defp outcome_colour(%{status: "actioned"}), do: "var(--lamp)"
  defp outcome_colour(_), do: "var(--bcm)"

  defp dismissals_line(1), do: "One previous report on this, dismissed"
  defp dismissals_line(n), do: "#{n} previous reports on this, all dismissed"

  defp audit_label("content_access"), do: "Read an unpublished perspective"
  defp audit_label("takedown"), do: "Took down a snapshot"
  defp audit_label("dismiss"), do: "Dismissed a report"
  defp audit_label("suspend"), do: "Suspended an account"
  defp audit_label("reinstate"), do: "Lifted a suspension"
  defp audit_label("warn"), do: "Warned an author"
  defp audit_label("fork_cleared"), do: "Left a fork up"
  defp audit_label(other), do: String.capitalize(String.replace(to_string(other), "_", " "))

  defp audit_detail(entry) do
    who =
      case entry.actor_id && Accounts.get(entry.actor_id) do
        nil -> nil
        actor -> actor.username
      end

    why = entry.metadata["why"] || entry.metadata["reason"]
    target = entry.target_id && "#{entry.target_type} ##{entry.target_id}"

    [who, target, why && "\"#{why}\""] |> Enum.filter(& &1) |> Enum.join(" · ")
  end

  defp suspension_lengths, do: [{"7 days", 7}, {"30 days", 30}, {"Until we say", nil}]

  defp suspension_line(nil), do: "Indefinite"
  defp suspension_line(0), do: "Lifts today"
  defp suspension_line(1), do: "1 day left"
  defp suspension_line(n), do: "#{n} days left"

  defp hidden_line(0), do: "Nothing of theirs was shared"
  defp hidden_line(1), do: "1 thing hidden"
  defp hidden_line(n), do: "#{n} things hidden"

  defp fork_line(%{entry: entry}) do
    author =
      case Accounts.get(to_int(entry.owner_id)) do
        nil -> "someone"
        user -> user.username
      end

    "By #{author} · descended from what was taken down"
  end

  defp mint(socket, opts) do
    safe(socket, fn ->
      case Accounts.create_invite(socket.assigns.current_user, opts) do
        {:ok, _} -> {:noreply, socket |> put_flash(:info, "Minted one.") |> load()}
        _ -> {:noreply, put_flash(socket, :error, "Couldn't mint one.")}
      end
    end)
  end

  # What this invite is and what has happened to it. A reusable one leads with the fact
  # that it stays open, because that is the thing about it somebody needs to know
  # before they send it anywhere.
  defp invite_line(%{revoked_at: at} = i) when not is_nil(at),
    do: "Closed · #{used_count(i)} · made #{month(i.inserted_at)}"

  defp invite_line(%{reusable: true} = i),
    do: "Reusable — stays valid · #{used_count(i)} · made #{month(i.inserted_at)}"

  defp invite_line(%{redeemed_by_id: nil, inserted_at: at}), do: "Unused · made #{month(at)}"

  defp invite_line(%{redeemed_by_id: id, inserted_at: at}) do
    case Accounts.get(id) do
      nil -> "Used · #{month(at)}"
      user -> "Used by #{user.username} · #{month(at)}"
    end
  end

  defp used_count(%{uses: n}) when is_integer(n) and n > 0,
    do: "used #{n} #{if n == 1, do: "time", else: "times"}"

  defp used_count(_), do: "never used"

  defp admin_line(%{role: "superadmin"}), do: "The first account"
  defp admin_line(%{inserted_at: at}), do: "Admin since #{month(at)}"

  defp entry_name(entry) do
    case Library.payload(entry) do
      %{name: n} when is_binary(n) and n != "" -> n
      %{bible: %{name: n}} when is_binary(n) and n != "" -> n
      _ -> "Untitled #{entry.kind}"
    end
  end

  defp item_line(entry) do
    owner =
      case Accounts.get(to_int(entry.owner_id)) do
        nil -> "someone"
        user -> user.username
      end

    "#{entry.kind} · #{owner} · #{entry.visibility}"
  end

  # Coarse on purpose: a moderator needs "this has been waiting three hours", not a
  # timestamp they have to subtract from now.
  defp age(%{inserted_at: at}) when not is_nil(at) do
    case NaiveDateTime.diff(NaiveDateTime.utc_now(), at, :second) do
      s when s < 3600 -> "#{max(div(s, 60), 1)}m"
      s when s < 86_400 -> "#{div(s, 3600)}h"
      s -> "#{div(s, 86_400)}d"
    end
  end

  defp age(_), do: "?"

  defp month(nil), do: "—"
  defp month(at), do: Calendar.strftime(at, "%B")

  defp time_of(nil), do: ""
  defp time_of(at), do: Calendar.strftime(at, "%H:%M")

  # Naming what's destroyed rather than "a campaign" — the weight of the action should
  # be visible at the moment of taking it.
  defp takedown_confirm(assigns) do
    forks =
      case assigns.open.item do
        nil -> 0
        item -> max(length(Library.family(item)) - 1, 0)
      end

    base =
      "Take this down? The public copy and the author's own — they lose the thing, not just its listing."

    if forks > 0,
      do: base <> " #{forks} fork(s) go to the review lane rather than down with it.",
      else: base
  end

  defp to_int(nil), do: nil
  defp to_int(n) when is_integer(n), do: n

  defp to_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp to_int(_), do: nil
end
