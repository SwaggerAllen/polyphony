defmodule PolyphonyWeb.AdminLive do
  @moduledoc """
  V13 (admin & moderation): the report queue and its actions, plus invite creation
  and role management. Every action is authorized + audited server-side by
  `Polyphony.Moderation` / `Polyphony.Accounts` — this view only surfaces them.
  """
  use PolyphonyWeb, :live_view

  alias Polyphony.{Moderation, Accounts}

  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Admin", invite_url: nil, viewed: nil) |> load()}
  end

  defp load(socket) do
    assign(socket, reports: Moderation.list_open(), admins: Accounts.list_admins())
  end

  # ── Report actions ─────────────────────────────────────────────────────────────

  def handle_event("take_down", %{"rid" => id, "reason" => reason}, socket) do
    report = Moderation.get_report(String.to_integer(id))
    Moderation.take_down(socket.assigns.current_user, report, reason)
    {:noreply, socket |> put_flash(:info, "Taken down.") |> load()}
  end

  def handle_event("dismiss", %{"id" => id}, socket) do
    report = Moderation.get_report(String.to_integer(id))
    Moderation.dismiss(socket.assigns.current_user, report)
    {:noreply, socket |> put_flash(:info, "Dismissed.") |> load()}
  end

  def handle_event("suspend", %{"id" => id}, socket) do
    report = Moderation.get_report(String.to_integer(id))
    Moderation.suspend_user(socket.assigns.current_user, report)
    {:noreply, socket |> put_flash(:info, "Account suspended.") |> load()}
  end

  def handle_event("warn", %{"id" => id, "message" => msg}, socket) do
    report = Moderation.get_report(String.to_integer(id))
    Moderation.warn_owner(socket.assigns.current_user, report, msg)
    {:noreply, put_flash(socket, :info, "Owner warned.")}
  end

  def handle_event("view", %{"id" => id}, socket) do
    report = Moderation.get_report(String.to_integer(id))

    case Moderation.access_report_content(socket.assigns.current_user, report) do
      {:ok, entries} -> {:noreply, assign(socket, viewed: {report.id, entries})}
      _ -> {:noreply, put_flash(socket, :error, "Could not open report content.")}
    end
  end

  # ── Invites + roles ─────────────────────────────────────────────────────────────

  def handle_event("invite", _params, socket) do
    case Accounts.create_invite(socket.assigns.current_user) do
      {:ok, invite} ->
        {:noreply, assign(socket, invite_url: "#{url(~p"/signup")} · code: #{invite.token}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Only admins can create invites.")}
    end
  end

  def handle_event("promote", %{"username" => username}, socket) do
    with %Accounts.User{} = target <- Accounts.get_by_username(username),
         {:ok, _} <- Accounts.promote_to_admin(socket.assigns.current_user, target) do
      {:noreply, socket |> put_flash(:info, "@#{username} is now an admin.") |> load()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not promote @#{username}.")}
    end
  end

  def render(assigns) do
    ~H"""
    <h1>Admin &amp; moderation</h1>

    <div class="card">
      <div class="row">
        <h3>Invites</h3>
        <div class="spacer"></div>
        <button class="btn sm" phx-click="invite">Create invite</button>
      </div>
      <p :if={@invite_url} class="dim">New invite: <code><%= @invite_url %></code></p>
    </div>

    <div class="card">
      <h3>Admins</h3>
      <ul><li :for={a <- @admins}>@<%= a.username %> <span class="faint">· <%= a.role %></span></li></ul>
      <form phx-submit="promote" class="row">
        <input type="text" name="username" placeholder="username to promote" />
        <button class="btn ghost sm" type="submit">Promote to admin</button>
      </form>
    </div>

    <h2>Open reports</h2>
    <div :if={@reports == []} class="list-empty">No open reports.</div>
    <div :for={r <- @reports} class="card">
      <div class="row">
        <div>
          <span class="badge"><%= r.reason %></span>
          <span class="faint"><%= r.item_type %> #<%= r.item_id %></span>
          <p style="margin:.3rem 0 0;"><%= r.detail %></p>
        </div>
      </div>
      <div class="row" style="margin-top:.5rem;gap:.4rem;flex-wrap:wrap;">
        <button class="btn ghost sm" phx-click="view" phx-value-id={r.id}>View in context</button>
        <form phx-submit="take_down" class="row" style="gap:.3rem;">
          <input type="hidden" name="rid" value={r.id} />
          <input type="text" name="reason" placeholder="takedown reason" style="width:12rem;" />
          <button class="btn danger sm" type="submit">Take down</button>
        </form>
        <button class="btn ghost sm" phx-click="dismiss" phx-value-id={r.id}>Dismiss</button>
        <button class="btn danger sm" phx-click="suspend" phx-value-id={r.id}
          data-confirm="Suspend this account?">Suspend</button>
      </div>

      <div :if={match?({id, _} when id == r.id, @viewed)} class="card" style="margin-top:.5rem;background:var(--bg-3);">
        <p class="faint">Owner content (audited access):</p>
        <ul><li :for={e <- elem(@viewed, 1)}><%= e.kind %> · <%= e.visibility %></li></ul>
      </div>
    </div>
    """
  end
end
