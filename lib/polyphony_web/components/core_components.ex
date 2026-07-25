defmodule PolyphonyWeb.CoreComponents do
  @moduledoc "A lean set of shared function components (hand-written, no generators)."
  use Phoenix.Component

  @doc "Render the info/error flash messages."
  attr(:flash, :map, default: %{})

  def flash_group(assigns) do
    ~H"""
    <div id="flash">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
    </div>
    """
  end

  attr(:kind, :atom, required: true)
  attr(:flash, :map, required: true)

  def flash(assigns) do
    assigns = assign(assigns, :msg, Phoenix.Flash.get(assigns.flash, assigns.kind))

    ~H"""
    <div :if={@msg} class={"flash #{@kind}"} role="alert" phx-click={"lv:clear-flash"} phx-value-key={@kind}>
      <%= @msg %>
    </div>
    """
  end

  @doc "A visibility badge for a library entry."
  attr(:visibility, :string, required: true)

  def visibility_badge(assigns) do
    ~H"""
    <span class={"badge #{@visibility}"}><%= @visibility %></span>
    """
  end

  @doc "One of the three distinct scene waiting states (FS principle)."
  attr(:state, :string, required: true)
  attr(:label, :string, required: true)

  def waiting(assigns) do
    ~H"""
    <div class={"waiting #{@state}"}>
      <span class="dot"></span><span><%= @label %></span>
    </div>
    """
  end
end
