defmodule PolyphonyWeb.WaitingPlaceholderFeatureTest do
  @moduledoc """
  That the waiting placeholders are actually **on the screen**, measured in a real browser.

  The Director's placeholder shipped correct in every way `Phoenix.LiveViewTest` can
  see: the right component, the right classes, `role="status"`, two `.skel` bars in the
  markup with the right widths. In a browser it was invisible. Hitting Continue drew the
  two rules, the hanging dash and "The Director" with an empty space between them — a
  Director line that had come back blank.

  The cause is CSS and only CSS. `world_move`'s stage layout is a flex row, and its text
  column had no `flex-1`, so its width came from its content. A child sized in *percent*
  then resolves against a width that depends on that child — circular, which CSS settles
  at zero. Text was fine, because text has an intrinsic width. Skeleton bars have nothing
  but a percentage, so they collapsed.

  No assertion over rendered HTML can catch that: the markup is identical either way. So
  this measures `offsetWidth`, which is the actual claim the placeholder makes — *there
  is something here, and the words will land in it*.

  Tagged `:feature`; excluded from the default suite. Run with `mix test --only feature`
  (after `bin/setup-chromedriver`).
  """
  use PolyphonyWeb.FeatureCase, async: false
  @moduletag :feature

  import Wallaby.Query

  alias Polyphony.Broadcast

  setup do
    # The omniscient play view swaps the whole transcript for the raw event stream when
    # the debug flags are on — and those flags are node-wide application env, so the
    # debug-drawer feature test's clicks leak into whatever runs after it. A placeholder
    # that can't render is not a placeholder that collapsed, so this test states its own
    # precondition rather than inheriting one.
    Polyphony.DebugFlags.set(:events, false)
    Polyphony.DebugFlags.set(:trace, false)
    :ok
  end

  # The loop's phase now survives a page load (`Broadcast.Activity`), which is what makes
  # a mid-beat screen reachable from a plain `visit/2` at all.
  #
  # Polls rather than measuring once. The suite runs eight browsers at a time, and a
  # fixed wait for "the page is ready" is the classic way a real assertion turns into a
  # timing one — a zero here has to mean *collapsed*, never *not painted yet*. A bar that
  # is genuinely zero-width burns the whole window and then fails, which is the right
  # trade for the one direction that matters.
  defp measure(session, selector, deadline \\ 8_000) do
    width = width_of(session, selector)

    cond do
      width > 0 -> width
      deadline <= 0 -> width
      true -> measure(session, selector, deadline - 250)
    end
  end

  defp width_of(session, selector) do
    Wallaby.Browser.execute_script(
      session,
      """
      const el = document.querySelector(arguments[0])
      if (!el) return -1
      return Math.round(el.getBoundingClientRect().width)
      """,
      [selector],
      fn width -> send(self(), {:width, width}) end
    )

    receive do
      {:width, w} -> w
    after
      5_000 -> flunk("no width came back for #{selector}")
    end
  end

  feature "the Director's placeholder has width, not just markup", %{session: session} do
    user = user_fixture()
    scene = scene_with_cast()

    Broadcast.announce_progress(scene, :director, beat: 1)

    session =
      session
      |> sign_in(user)
      |> visit("/play/#{scene}")
      |> assert_has(css(".m-world"))

    # The number that matters. Zero here is exactly what shipped: two bars in the DOM,
    # nothing on the screen. A real transcript column is hundreds of pixels wide; 40 is
    # comfortably below anything that could read as a line and far above zero.
    assert measure(session, ".m-world .skel") > 40
  end

  feature "and so does a character's", %{session: session} do
    user = user_fixture()
    scene = scene_with_cast()

    Broadcast.announce_progress(scene, :generating, subject: "mira", beat: 1)

    session =
      session
      |> sign_in(user)
      |> visit("/play/#{scene}")
      |> assert_has(css(".m-writing"))

    # This one was never broken — `m-writing` puts the bars in a block container, so the
    # percentages had something to resolve against. It is here because the two
    # placeholders are one idea drawn twice, and only one of them was being watched.
    assert measure(session, ".m-writing .skel") > 40
  end
end
