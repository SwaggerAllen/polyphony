defmodule PolyphonyWeb.SettingsLive do
  @moduledoc """
  V10/V12: account, profile, and the cost dashboard. Email never appears here
  (username is the public handle); spend (§B5) is surfaced and controllable.

  No proactive-analysis control is shown: there is no automated safety/scene
  analysis today (it's deferred under-18 work), and a switch for an absent feature
  implies processing that isn't happening (backlog §4b.2). The §C opt-out seam
  stays in the domain (`Accounts.set_proactive_opt_out`, `DataAccess`) for when
  such a feature exists — at which point the design places the control per campaign,
  not per account.
  """
  use PolyphonyWeb, :live_view

  alias Polyphony.{Accounts, Costs}

  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Settings") |> refresh()}
  end

  defp refresh(socket) do
    user = Accounts.get(socket.assigns.current_user.id)

    assign(socket,
      current_user: user,
      spent_today: Costs.spent_today(user.id),
      needs_reconsent: Accounts.needs_reconsent?(user.id)
    )
  end

  def handle_event("profile", params, socket) do
    safe(socket, fn ->
      Accounts.update_profile(socket.assigns.current_user, %{
        display_name: params["display_name"],
        bio: params["bio"],
        avatar_url: params["avatar_url"]
      })

      {:noreply, socket |> put_flash(:info, "Profile saved.") |> refresh()}
    end)
  end

  def handle_event("username", %{"username" => username}, socket) do
    safe(socket, fn ->
      case Accounts.change_username(socket.assigns.current_user, username) do
        {:ok, _} ->
          {:noreply, socket |> put_flash(:info, "Username changed.") |> refresh()}

        {:error, :rate_limited} ->
          {:noreply, put_flash(socket, :error, "You can only change your username once a month.")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "That username is taken or invalid.")}
      end
    end)
  end

  def handle_event("consent", _params, socket) do
    safe(socket, fn ->
      for doc <- socket.assigns.needs_reconsent,
          do: Accounts.accept_consent(socket.assigns.current_user.id, doc)

      {:noreply, socket |> put_flash(:info, "Thanks — consent updated.") |> refresh()}
    end)
  end

  def render(assigns) do
    ~H"""
    <h1>Settings</h1>

    <div :if={@needs_reconsent != []} class="card">
      <h3>Policy update</h3>
      <p class="dim">Our policies changed. Please review and accept to continue.</p>
      <button class="btn" phx-click="consent">Accept updated policies</button>
    </div>

    <div class="card">
      <h3>Profile</h3>
      <form id="profile-form" phx-submit="profile">
        <label>Display name</label>
        <input type="text" name="display_name" value={@current_user.display_name} />
        <label>Avatar URL</label>
        <input type="text" name="avatar_url" value={@current_user.avatar_url} />
        <label>Bio</label>
        <textarea name="bio"><%= @current_user.bio %></textarea>
        <br /><br />
        <button class="btn" type="submit">Save profile</button>
      </form>
    </div>

    <div class="card">
      <h3>Username</h3>
      <form id="username-form" phx-submit="username" class="row">
        <input type="text" name="username" value={@current_user.username} />
        <button class="btn ghost" type="submit">Change</button>
      </form>
      <p class="faint">Rate-limited to one change per month.</p>
    </div>

    <div class="card">
      <h3>Usage &amp; cost</h3>
      <p>Spent in the last 24h: <strong><%= fmt_cost(@spent_today) %></strong></p>
      <p class="faint">Generation pauses automatically if you hit your daily or per-campaign cap.</p>
    </div>

    """
  end

  defp fmt_cost(microcents) when is_integer(microcents), do: "#{microcents} units"
  defp fmt_cost(_), do: "0 units"
end
