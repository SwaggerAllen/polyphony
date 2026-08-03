defmodule PolyphonyWeb.HomeLive do
  @moduledoc "Landing page (V-none): the pitch + the way in."
  use PolyphonyWeb, :live_view

  alias PolyphonyWeb.Kit

  def mount(_params, _session, socket), do: {:ok, assign(socket, page_title: "Polyphony")}

  def render(assigns) do
    ~H"""
    <div class="max-w-md mx-auto px-4 py-10">
      <Kit.sheet class="p-5">
        <div class="ttl text-[22px] font-semibold mb-2">Polyphony</div>
        <p class="text-[14px] leading-relaxed dim mb-4">
          An event-sourced, multi-agent roleplay engine. One agent per character plus a
          world Director; every character sees only their filtered slice of the story.
          Dramatic irony is structural — a property of the data, never a prompt.
        </p>
        <div class="flex flex-wrap gap-1.5">
          <.link :if={@current_user} navigate={~p"/library"} class="btn btn-pri">Your stuff</.link>
          <.link :if={is_nil(@current_user)} navigate={~p"/signup"} class="btn btn-pri">
            Create an account
          </.link>
          <.link :if={is_nil(@current_user)} navigate={~p"/login"} class="btn btn-gh">Sign in</.link>
          <.link navigate={~p"/browse"} class="btn btn-gh">Browse published</.link>
        </div>
      </Kit.sheet>
    </div>
    """
  end
end
