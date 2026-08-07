defmodule PolyphonyWeb.ResumeLive do
  @moduledoc """
  Coming back to a device that has been signed in before (§B2).

  The session cookie has no `max_age` — it dies with the browser, which on a phone is
  whenever the OS decides — so the common way to meet the sign-in screen is not "I have
  no account", it is "I had one ten minutes ago". Sending that person to a form is
  asking them to retype an address the server could have remembered, and the reward for
  typing it correctly is an email either way.

  So: one button. Everything else on the page is an escape route, because a screen that
  assumes it knows who you are has to be trivial to correct.

  Built from the same kit sheet as `LoginLive`, and its sent state is deliberately the
  same copy — it is the same event, and two phrasings for one thing would read as two
  different things having happened.
  """
  use PolyphonyWeb, :live_view

  require Logger

  alias PolyphonyWeb.{Auth, Screens}

  def mount(_params, session, socket) do
    # No cookie, or a cookie for an account that has since gone: this page has nothing
    # to offer, and the form does.
    case Auth.remembered_user(session) do
      nil ->
        {:ok, redirect(socket, to: ~p"/login")}

      user ->
        {:ok, assign(socket, page_title: "Welcome back", user: user, sent: false, dev_link: nil)}
    end
  end

  def handle_event("send", _params, socket), do: {:noreply, deliver(socket)}

  def handle_event("again", _params, socket),
    do: {:noreply, socket |> deliver() |> put_flash(:info, "Sent again.")}

  defp deliver(socket) do
    user = socket.assigns.user

    # The address is never logged whole: this line reaches the debug drawer, which is
    # not admin-gated. The handle is the public identity by design, so it carries the
    # "who" without carrying the auth-only half.
    Logger.info("[mail] resume requested for @#{user.username}")

    assign(socket, sent: true, dev_link: dev_link(Auth.deliver_magic_link(user)))
  end

  # Same fail-closed compile-time branch as `LoginLive`: outside prod the link is
  # surfaced so the flow works with no mailer, and a prod build contains no clause that
  # can return it.
  @expose_magic_link Application.compile_env(:polyphony, :expose_magic_link, false) == true

  if @expose_magic_link do
    defp dev_link(url), do: url
  else
    defp dev_link(_url), do: nil
  end

  def render(assigns) do
    ~H"""
    <Screens.Resume.screen
      current_user={@current_user}
      dev_link={@dev_link}
      sent={@sent}
      user={@user}
    />
    """
  end
end
