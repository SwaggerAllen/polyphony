defmodule PolyphonyWeb.CoreComponents do
  @moduledoc """
  A lean set of shared function components (hand-written, no generators).

  Anything with a visual identity belongs in `PolyphonyWeb.Kit`, ported from the
  design. What's left here is the glue between Phoenix's conventions and those
  components — the flash, which has to read `Phoenix.Flash` before it can be a
  toast.
  """
  use Phoenix.Component

  alias PolyphonyWeb.Kit

  @doc """
  A flash message, as the kit's toast.

  Dismissible by tapping it, which is also why it's `pointer-events-auto` inside
  the layout's pass-through overlay: the region ignores clicks so it can't block
  the screen underneath, and only the toast itself takes them back.
  """
  attr(:kind, :atom, required: true)
  attr(:flash, :map, required: true)

  def flash(assigns) do
    assigns = assign(assigns, :msg, Phoenix.Flash.get(assigns.flash, assigns.kind))

    ~H"""
    <Kit.toast
      :if={@msg}
      kind={if @kind == :error, do: :error, else: :ok}
      dismiss
      class="pointer-events-auto cursor-pointer mx-auto w-full max-w-md"
      role="alert"
      aria-label="Dismiss"
      phx-click="lv:clear-flash"
      phx-value-key={@kind}
    >
      <%= @msg %>
    </Kit.toast>
    """
  end

  @doc "A visibility badge for a library entry. Unported — see `Kit.pill/1`."
  attr(:visibility, :string, required: true)

  def visibility_badge(assigns) do
    ~H"""
    <span class={"badge #{@visibility}"}><%= @visibility %></span>
    """
  end
end
