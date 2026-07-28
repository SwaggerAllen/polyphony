defmodule PolyphonyWeb.PlayFeatureTest do
  @moduledoc """
  The dramatic-irony guarantee, proven through a **real browser** over a live
  LiveSocket WebSocket — the tier `Phoenix.LiveViewTest` can't reach (no JS, no
  socket, no real render). A whisper composed in the browser is visible to the
  omniscient author, silently absent for a bystander, and present for the
  addressee.

  Tagged `:feature`; excluded from the default suite. Run with
  `mix test --only feature`.
  """
  use PolyphonyWeb.FeatureCase, async: false
  @moduletag :feature

  import Wallaby.Query

  feature "a browser-composed whisper is occluded from a bystander but not the addressee",
          %{session: session} do
    user = user_fixture()
    scene = scene_with_cast()

    # As mira (you speak as whoever you view as): compose a whisper to otto through the
    # composer — audibility inferred from the text — which commits over the WebSocket
    # and streams back into the transcript.
    session
    |> sign_in(user)
    |> visit("/play/#{scene}?as=mira")
    |> fill_in(text_field("text"), with: "(whisper to otto: meet me at dawn)")
    |> click(button("Send"))
    |> assert_has(css("#transcript", text: "meet me at dawn"))

    # Bystander (cara): the page renders, but the whisper she wasn't part of is
    # structurally absent — occlusion is silent.
    session
    |> visit("/play/#{scene}?as=cara")
    |> assert_has(css("body", text: "Viewing as"))
    |> refute_has(css("#transcript", text: "meet me at dawn"))

    # Addressee (otto): the whisper is present.
    session
    |> visit("/play/#{scene}?as=otto")
    |> assert_has(css("#transcript", text: "meet me at dawn"))
  end
end
