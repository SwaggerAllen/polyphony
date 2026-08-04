defmodule PolyphonyWeb.DebugDrawerFeatureTest do
  @moduledoc """
  The debug drawer through a **real browser**, because its whole problem is one that
  only exists in a browser: it is a nested LiveView whose open/closed state is driven
  by client-side JS, and every server round-trip patches the DOM underneath it.

  The bug this pins: clicking Events or Trace — server events — collapsed the panel
  *and* took the button that reopens it with them. Open/closed lived in inline styles,
  so LiveView's patch re-asserted the template's `display:none` on the panel while
  nothing restored the toggle that JS had hidden. Two elements, opposite failures,
  same cause.

  No in-process test can see this. `Phoenix.LiveViewTest` has no DOM patching and no
  JS, so it renders the drawer correctly and reports success either way.

  Tagged `:feature`; run with `mix test --only feature`.
  """
  use PolyphonyWeb.FeatureCase, async: false
  @moduletag :feature

  import Wallaby.Query

  setup do
    # `DebugLog` joins the supervision tree only when `:debug_drawer` is on at boot,
    # and it is off in test — so without this the drawer's mount calls a GenServer
    # that isn't running and takes the whole page down.
    Application.put_env(:polyphony, :debug_drawer, true)
    start_supervised!({Polyphony.DebugLog, []})
    on_exit(fn -> Application.put_env(:polyphony, :debug_drawer, false) end)
    :ok
  end

  # Wallaby's visibility check is the whole assertion here, so ask the browser
  # directly rather than trusting a class or an attribute.
  defp shown?(session, selector) do
    Wallaby.Browser.has?(session, css(selector, count: 1, visible: true))
  end

  feature "a server round-trip doesn't collapse the drawer", %{session: session} do
    session =
      session
      |> visit("/login")
      |> click(css("#debug-drawer-toggle"))

    assert shown?(session, "#debug-drawer-body")
    refute shown?(session, "#debug-drawer-toggle")

    # Events and Trace are `phx-click`s: they hit the server, it re-renders, and
    # LiveView patches this drawer's DOM. The drawer must survive its own updates.
    session = click(session, css("button[phx-click='toggle_events']"))
    assert shown?(session, "#debug-drawer-body"), "toggling Events collapsed the panel"

    session = click(session, css("button[phx-click='toggle_trace']"))
    assert shown?(session, "#debug-drawer-body"), "toggling Trace collapsed the panel"

    # The failure that made it unrecoverable: with the panel shut and the toggle
    # hidden too, there was no way back to the log short of reloading the page.
    refute shown?(session, "#debug-drawer-toggle"),
           "the toggle reappeared while the panel was still open"
  end

  feature "it still closes and reopens after a round-trip", %{session: session} do
    session =
      session
      |> visit("/login")
      |> click(css("#debug-drawer-toggle"))
      |> click(css("button[phx-click='toggle_events']"))
      |> click(css("#debug-drawer-close"))

    assert shown?(session, "#debug-drawer-toggle")
    refute shown?(session, "#debug-drawer-body")

    session = click(session, css("#debug-drawer-toggle"))

    assert shown?(session, "#debug-drawer-body"), "the drawer would not reopen"
  end

  feature "tucking it clears the corner, and it can be got back", %{session: session} do
    session =
      session
      |> visit("/login")
      |> click(css("#debug-drawer-toggle"))
      |> click(css("#debug-drawer-tuck"))

    # Tucked shrinks the tab rather than hiding it: the state persists, and a control
    # you cannot find again is worse than one that is in the way.
    refute shown?(session, "#debug-drawer-body"), "tucking left the panel open"
    assert shown?(session, "#debug-drawer-toggle")

    assert width_of(session, "#debug-drawer-toggle") < 60,
           "the tab is still full width — nothing was tucked"

    # First tap restores the tab, second opens the drawer. A sliver on the screen edge
    # is easy to hit by accident, and throwing a full-height panel over the app on that
    # tap would undo the reason it was tucked.
    session = click(session, css("#debug-drawer-toggle"))
    refute shown?(session, "#debug-drawer-body"), "a tap on the sliver opened the panel"
    assert width_of(session, "#debug-drawer-toggle") > 60

    session = click(session, css("#debug-drawer-toggle"))
    assert shown?(session, "#debug-drawer-body")
  end

  feature "it stays tucked on the next page, which is the point of tucking it",
          %{session: session} do
    session =
      session
      |> visit("/login")
      |> click(css("#debug-drawer-toggle"))
      |> click(css("#debug-drawer-tuck"))
      |> visit("/signup")

    # A tab that un-tucks itself on the next navigation is back on top of whatever the
    # app puts in that corner, which is the whole complaint.
    assert width_of(session, "#debug-drawer-toggle") < 60
  end

  # The browser's own measurement, not a class: the assertion is that the thing takes
  # up less room, and a class name is a claim about that rather than the fact.
  defp width_of(session, selector) do
    Wallaby.Browser.execute_script(
      session,
      "return document.querySelector(arguments[0]).getBoundingClientRect().width",
      [selector],
      fn width -> send(self(), {:width, width}) end
    )

    receive do
      {:width, width} -> width
    after
      2_000 -> flunk("no width for #{selector}")
    end
  end

  feature "the log keeps streaming into an open drawer", %{session: session} do
    session =
      session
      |> visit("/login")
      |> click(css("#debug-drawer-toggle"))

    # A request the server logs, which must arrive in the open panel over PubSub —
    # the drawer surviving a patch is worth nothing if it stops receiving.
    session = click(session, css("button[phx-click='toggle_events']"))

    assert shown?(session, "#debug-log-list")
    assert shown?(session, "#debug-drawer-body")
  end
end
