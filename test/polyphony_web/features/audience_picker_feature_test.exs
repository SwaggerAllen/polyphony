defmodule PolyphonyWeb.AudiencePickerFeatureTest do
  @moduledoc """
  The audience picker through a **real browser**, because the bug it fixes was
  entirely a matter of where on the screen the thing landed — and that is the one
  question `Phoenix.LiveViewTest` cannot answer. It has no layout: it rendered the
  picker correctly the whole time it was unusable.

  What went wrong: the picker was an ordinary sheet in the document flow, after the
  form on an authoring screen several viewports tall. Opened from a fact halfway
  down, it appeared far below the fold — so it read as nothing having happened, its
  close was off-screen, and Save still looked live while the panel was what you were
  actually editing.

  So the assertions here are measurements, taken at phone size: is the panel in the
  viewport, and is the page underneath genuinely out of reach.

  Tagged `:feature`; run with `mix test --only feature`.
  """
  use PolyphonyWeb.FeatureCase, async: false
  @moduletag :feature

  import Wallaby.Query

  alias Polyphony.Library
  alias Polyphony.Owner
  alias Polyphony.Authoring.CharacterSheet
  alias Polyphony.Authoring.CharacterSheet.Fact

  @kestrel "She's been signing for the Kestrel's cargo since March."

  setup %{session: session} do
    user = user_fixture()

    # Enough prose that the fact list sits well below the fold — the condition the
    # inline panel failed under, and the only one worth measuring.
    filler = String.duplicate("The tide comes in over the flats twice a day. ", 60)

    wren =
      Library.put(%{
        owner: Owner.of(user),
        kind: "character",
        payload: %CharacterSheet{
          name: "Wren Ashgrove",
          status: :full,
          premise: filler,
          voice: filler,
          facts: [%Fact{statement: @kestrel, concealed: true}]
        }
      })

    session =
      session
      |> resize_window(390, 780)
      |> sign_in(user)
      |> visit("/authoring/character/#{wren.id}")

    %{session: session}
  end

  # The browser's own numbers. A class name is a claim about the layout; this is the
  # layout.
  defp script(session, js, args \\ []) do
    Wallaby.Browser.execute_script(session, "return " <> js, args, &send(self(), {:js, &1}))

    receive do
      {:js, value} -> value
    after
      2_000 -> flunk("no result from: #{js}")
    end
  end

  # The fact's own ⋯ menu is a `<details>`, so it has to be opened before the control
  # that opens the picker exists to click.
  defp open_picker(session) do
    # `<details>` toggles, and it stays open across the picker being dismissed — so
    # clicking the summary unconditionally would shut it on the second call.
    session = if has?(session, css("#fact-0[open]")), do: session, else: click(session, summary())

    # **Wait for it to actually be open before handing the session back.** Wallaby's
    # `click/2` returns once the click is dispatched, and the picker arrives on a
    # LiveView round-trip — so a caller that goes straight to `elementFromPoint` is
    # racing the DOM patch. That is not hypothetical: "tapping away closes it" failed in
    # CI probing (width/2, 8) and getting back the header's `row`, because the scrim was
    # not in the document yet. `assert_has/2` retries to Wallaby's timeout, which is the
    # synchronisation the other assertions here were getting by accident from `has?/2`.
    session
    |> click(css("button[phx-click='open_audience'][phx-value-index='0']", count: 1))
    |> assert_has(css(".modal", visible: true))
  end

  defp summary, do: css("#fact-0 summary", count: 1)

  feature "it opens where you are, not where the document put it", %{session: session} do
    session = open_picker(session)

    assert has?(session, css(".modal", count: 1, visible: true))

    box =
      script(
        session,
        "(() => { const r = document.querySelector('.modal').getBoundingClientRect();
        return {top: r.top, bottom: r.bottom, height: r.height}; })()"
      )

    # Inside the viewport on both edges. The old panel's top was several thousand
    # pixels down the page, so this is the assertion that would have failed.
    assert box["top"] >= 0, "the panel opened above the viewport"
    assert box["bottom"] <= 781, "the panel opened below the fold — top was #{box["top"]}"
    assert box["height"] > 100, "the panel collapsed to nothing"
  end

  feature "the page underneath is genuinely out of reach while it's open",
          %{session: session} do
    session = open_picker(session)

    # The complaint was that Save "doesn't work" with the picker open. It always
    # worked — you just couldn't see that it had, because the panel stayed put and
    # was nowhere near your viewport. Now the scrim makes that state honest: while
    # the picker is open, a tap on the page hits the scrim and closes it.
    covered =
      script(
        session,
        "(() => { const r = document.querySelector('.modal').getBoundingClientRect();
        const el = document.elementFromPoint(r.left + r.width / 2, Math.max(4, r.top / 2));
        return el && (el.classList.contains('scrim') || el.closest('.overlay') !== null); })()"
      )

    assert covered, "the page was still clickable through the overlay"
  end

  feature "tapping away closes it, and so does Escape", %{session: session} do
    session = open_picker(session)

    # Tap the page above the sheet — resolved by the browser's own hit-testing rather
    # than by a selector, since what's being pinned is that the *scrim* is what a tap
    # up there lands on. Wallaby clicks an element's centre, and the sheet covers the
    # centre of a phone viewport, so a `click(css(".scrim"))` would hit the panel.
    assert script(session, "(() => { const el = document.elementFromPoint(
             window.innerWidth / 2, 8); el.click(); return el.className; })()") =~ "scrim"

    refute has?(session, css(".modal", visible: true)), "tapping away left it open"

    session = open_picker(session) |> send_keys([:escape])
    refute has?(session, css(".modal", visible: true)), "Escape left it open"
  end
end
