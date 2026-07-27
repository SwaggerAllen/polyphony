defmodule PolyphonyWeb.DebugDrawerLiveTest do
  @moduledoc """
  The debug drawer is embedded in the root layout (a nested `live_render`) only when
  `:debug_drawer` is enabled — present on the page when on, gone when off.
  """
  use PolyphonyWeb.ConnCase, async: false

  setup do
    previous = Application.get_env(:polyphony, :debug_drawer, false)
    Application.put_env(:polyphony, :debug_drawer, true)
    start_supervised!(Polyphony.DebugLog)
    on_exit(fn -> Application.put_env(:polyphony, :debug_drawer, previous) end)
    :ok
  end

  test "renders on a page when enabled", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)
    assert html =~ ~s(id="debug-drawer")
    assert html =~ "Session log"
  end

  test "is absent when disabled", %{conn: conn} do
    Application.put_env(:polyphony, :debug_drawer, false)
    html = conn |> get(~p"/") |> html_response(200)
    refute html =~ ~s(id="debug-drawer")
  end
end
