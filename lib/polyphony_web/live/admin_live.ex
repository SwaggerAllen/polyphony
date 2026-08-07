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
  alias PolyphonyWeb.Screens

  @tabs ~w(waiting decided suspended invites admins)

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Moderation", open: nil, unlocking: nil, viewed: nil)
     |> load()}
  end

  def handle_params(params, _uri, socket) do
    tab = if params["tab"] in @tabs, do: params["tab"], else: "waiting"
    {:noreply, socket |> assign(tab: tab) |> assign_open(params["report"]) |> assign_lines()}
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
    |> assign_lines()
  end

  # Every line on this screen that names a person or an artifact used to resolve it in
  # the markup, one `Accounts.get/1` or `Library.get/1` per row per render — the queue,
  # the audit trail, the invite list and the fork list all did it. Resolved once here
  # and keyed by `{kind, id}`, which is how the markup asks.
  defp assign_lines(socket) do
    %{
      lanes: lanes,
      decided: decided,
      audit: audit,
      invites: invites,
      viewed: viewed,
      open: open
    } = Map.merge(%{viewed: [], open: nil}, Map.new(socket.assigns))

    # `lanes.forks` is a different shape — entry rows, not reports — so it is taken
    # separately rather than swept up with the two report lanes.
    forks = Map.get(lanes, :forks, [])

    reports =
      Map.get(lanes, :urgent, []) ++
        Map.get(lanes, :rest, []) ++ List.wrap(decided) ++ List.wrap(open && open.report)

    items = List.wrap(viewed) ++ List.wrap(open && open.item)
    named = items ++ Enum.map(forks, & &1.entry)

    lines =
      Map.new(
        for(r <- reports, into: %{}, do: {{:subject, r.id}, subject_name(r)})
        |> Map.merge(for r <- reports, into: %{}, do: {{:by, r.id}, by_line(r)})
        |> Map.merge(for a <- audit, into: %{}, do: {{:audit, a.id}, audit_detail(a)})
        |> Map.merge(for i <- invites, into: %{}, do: {{:invite, i.id}, invite_line(i)})
        |> Map.merge(for e <- items, into: %{}, do: {{:item, e.id}, item_line(e)})
        |> Map.merge(for f <- forks, into: %{}, do: {{:fork, f.entry.id}, fork_line(f)})
        |> Map.merge(for e <- named, into: %{}, do: {{:name, e.id}, entry_name(e)})
      )

    assign(socket,
      lines: lines,
      fork_count:
        if(open && open.item, do: max(length(Library.family(open.item)) - 1, 0), else: 0)
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

    [who, "reported #{Screens.Admin.age(report)} ago"] |> Enum.filter(& &1) |> Enum.join(" · ")
  end

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

  defp fork_line(%{entry: entry}) do
    author =
      case Accounts.get(to_int(entry.owner_id)) do
        nil -> "someone"
        user -> user.username
      end

    "By #{author} · descended from what was taken down"
  end

  # What this invite is and what has happened to it. A reusable one leads with the fact
  # that it stays open, because that is the thing about it somebody needs to know
  # before they send it anywhere.
  defp invite_line(%{revoked_at: at} = i) when not is_nil(at),
    do: "Closed · #{Screens.Admin.used_count(i)} · made #{Screens.Admin.month(i.inserted_at)}"

  defp invite_line(%{reusable: true} = i),
    do:
      "Reusable — stays valid · #{Screens.Admin.used_count(i)} · made #{Screens.Admin.month(i.inserted_at)}"

  defp invite_line(%{redeemed_by_id: nil, inserted_at: at}),
    do: "Unused · made #{Screens.Admin.month(at)}"

  defp invite_line(%{redeemed_by_id: id, inserted_at: at}) do
    case Accounts.get(id) do
      nil -> "Used · #{Screens.Admin.month(at)}"
      user -> "Used by #{user.username} · #{Screens.Admin.month(at)}"
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

  defp entry_name(entry) do
    case Library.payload(entry) do
      %{name: n} when is_binary(n) and n != "" -> n
      %{bible: %{name: n}} when is_binary(n) and n != "" -> n
      _ -> "Untitled #{entry.kind}"
    end
  end

  defp mint(socket, opts) do
    safe(socket, fn ->
      case Accounts.create_invite(socket.assigns.current_user, opts) do
        {:ok, _} -> {:noreply, socket |> put_flash(:info, "Minted one.") |> load()}
        _ -> {:noreply, put_flash(socket, :error, "Couldn't mint one.")}
      end
    end)
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

  def render(assigns) do
    ~H"""
    <Screens.Admin.screen
      current_user={@current_user}
      tab={@tab}
      lanes={@lanes}
      decided={@decided}
      open={@open}
      viewed={@viewed}
      audit={@audit}
      invites={@invites}
      admins={@admins}
      suspended={@suspended}
      unlocking={@unlocking}
      lines={@lines}
      fork_count={@fork_count}
    />
    """
  end
end
