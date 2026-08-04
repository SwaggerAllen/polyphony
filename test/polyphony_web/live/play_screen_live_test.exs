defmodule PolyphonyWeb.PlayScreenLiveTest do
  @moduledoc """
  The play screen, ported from `ux/polyphony-play.html`.

  The design's two load-bearing decisions get pinned here, because both are easy to
  undo by accident while editing markup:

  1. **The register follows the viewer.** A character is reading, so `.page`; the
     omniscient author is working, so `.stage`. Same components either way.

  2. **The author has no composer.** To write a character you become them — the
     perspective control is how — so the GM's bar directs (Narrate, Continue)
     instead. A composer on the omniscient view would let an author speak as
     nobody, which is what the register split exists to prevent.

  The status strip's own logic lives in `PolyphonyWeb.Play.StripTest`; what's
  checked here is that the screen actually renders it, filtered per viewer.
  """
  use PolyphonyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Polyphony.{App, Library, Owner}
  alias Polyphony.Authoring.CharacterSheet
  alias Polyphony.Commands.{DeclareTurnOrder, EnterCharacter, OpenScene}
  alias Polyphony.Events.WorldEventOccurred
  alias Polyphony.Director.BeatOps

  setup :register_and_log_in_user

  defp scene_with_cast(user, names) do
    scene = "screen-" <> Integer.to_string(System.unique_integer([:positive]))

    :ok =
      App.dispatch(%OpenScene{
        scene_id: scene,
        location_id: "The quay",
        premise: "After the second bell.",
        opened_beat: 0
      })

    cast =
      Map.new(names, fn name ->
        entry =
          Library.put(%{
            owner: Owner.of(user),
            kind: "character",
            payload: %CharacterSheet{name: name, status: :full}
          })

        :ok =
          App.dispatch(%EnterCharacter{
            scene_id: scene,
            character_id: to_string(entry.id),
            beat: 1
          })

        {name, to_string(entry.id)}
      end)

    :ok = App.dispatch(%DeclareTurnOrder{scene_id: scene, beat: 1, order: Map.values(cast)})
    {scene, cast}
  end

  describe "registers" do
    test "a character reads, the author works", %{conn: conn, user: user} do
      {scene, cast} = scene_with_cast(user, ["Wren", "Ilias"])

      {:ok, _gm, gm_html} = live(conn, ~p"/play/#{scene}")
      assert gm_html =~ ~s(class="fr stage dark)

      {:ok, _player, player_html} = live(conn, ~p"/play/#{scene}?as=#{cast["Ilias"]}")
      assert player_html =~ ~s(class="fr page dark)
    end

    test "the header names the scene, with the perspective control beside it", %{
      conn: conn,
      user: user
    } do
      {scene, _cast} = scene_with_cast(user, ["Wren"])

      {:ok, _view, html} = live(conn, ~p"/play/#{scene}")

      assert html =~ "The quay"
      # The perspective control is the product's spine and has exactly one treatment.
      assert html =~ "viewas"
    end
  end

  describe "the author has no composer" do
    test "the omniscient view directs instead of writing", %{conn: conn, user: user} do
      {scene, cast} = scene_with_cast(user, ["Wren"])

      {:ok, _gm, gm_html} = live(conn, ~p"/play/#{scene}")
      refute gm_html =~ ~s(id="say-input")
      assert gm_html =~ ~s(phx-click="narrate_open")
      assert gm_html =~ ~s(phx-click="continue")

      # Becoming a character is what gets you a composer.
      {:ok, _player, player_html} = live(conn, ~p"/play/#{scene}?as=#{cast["Wren"]}")
      assert player_html =~ ~s(id="say-input")
      refute player_html =~ ~s(phx-click="narrate_open")
    end

    test "Narrate commits a world event at the current beat", %{conn: conn, user: user} do
      {scene, cast} = scene_with_cast(user, ["Wren", "Ilias"])

      {:ok, gm, _html} = live(conn, ~p"/play/#{scene}")
      gm |> element("button[phx-click=narrate_open]") |> render_click()

      gm
      |> form("form[phx-submit=narrate]", %{text: "The tide bell rings twice."})
      |> render_submit()

      assert Enum.any?(
               BeatOps.stored_events(scene),
               &match?(%WorldEventOccurred{content: "The tide bell rings twice."}, &1)
             )

      # A world event is the Director's own kind of move, so every member sees it —
      # it is narration, not a private note to the author.
      for id <- Map.values(cast) do
        {:ok, _v, html} = live(conn, ~p"/play/#{scene}?as=#{id}")
        assert html =~ "The tide bell rings twice."
      end
    end

    test "an empty narration is refused rather than committed", %{conn: conn, user: user} do
      {scene, _cast} = scene_with_cast(user, ["Wren"])

      {:ok, gm, _html} = live(conn, ~p"/play/#{scene}")
      gm |> element("button[phx-click=narrate_open]") |> render_click()
      html = gm |> form("form[phx-submit=narrate]", %{text: "   "}) |> render_submit()

      assert html =~ "Say what happens."
      refute Enum.any?(BeatOps.stored_events(scene), &match?(%WorldEventOccurred{}, &1))
    end
  end

  describe "the status strip" do
    test "renders a slot per cast member, marking the viewer's own", %{conn: conn, user: user} do
      {scene, cast} = scene_with_cast(user, ["Wren", "Ilias"])

      {:ok, _view, html} = live(conn, ~p"/play/#{scene}?as=#{cast["Ilias"]}")

      assert html =~ "slots"
      assert html =~ "WREN"
      assert html =~ "ILIAS"
      # The kit's ring: which slot is you, composable with whatever state it's in.
      assert html =~ "slot-you"
    end

    test "carries no beat number — the transcript rule owns that", %{conn: conn, user: user} do
      {scene, _cast} = scene_with_cast(user, ["Wren"])

      {:ok, _view, html} = live(conn, ~p"/play/#{scene}")

      assert html =~ "beat-rule"
      # One rule per beat, opened once.
      assert html |> String.split("beat-rule") |> length() == 2
    end
  end

  describe "the strip is people, so it goes to them" do
    test "each slot links to the character it stands for", %{conn: conn, user: user} do
      {scene, cast} = scene_with_cast(user, ["Wren", "Ilias"])
      {:ok, _view, html} = live(conn, ~p"/play/#{scene}")

      # A person on screen who isn't reachable reads as a bug. `character_id` *is* the
      # library entry id, so their sheet is one hop away.
      for id <- Map.values(cast) do
        assert html =~ ~s(href="/authoring/character/#{id}")
      end
    end
  end

  describe "the perspective picker" do
    test "carries a chevron, so it reads as a menu rather than a label",
         %{conn: conn, user: user} do
      {scene, _cast} = scene_with_cast(user, ["Wren"])
      {:ok, _view, html} = live(conn, ~p"/play/#{scene}")

      # `appearance:none` is what makes it a pill rather than an OS widget, and it
      # takes the platform's own chevron with it. `Kit.viewas` draws a ▾ as text; a
      # bare <select> can't hold one, so the pill wears it outside.
      assert html =~ ~s(class="viewas-select")
      assert html =~ "▾"
      # And the drift this ends: three screens had grown their own bare select.
      refute html =~ "viewas appearance-none"
    end
  end

  describe "the composer" do
    test "grows with what is typed, and can take the whole screen",
         %{conn: conn, user: user} do
      {scene, cast} = scene_with_cast(user, ["Wren"])
      [id | _] = Map.values(cast)
      {:ok, _view, html} = live(conn, ~p"/play/#{scene}?as=#{id}")

      # `.say-input` was referenced by the template and defined by no stylesheet, and
      # app.js short-circuits its JS fallback whenever the browser supports
      # `field-sizing` — so on a modern browser nothing sized it at all.
      assert html =~ "say-input"
      assert html =~ "say-bar"
      assert html =~ ~s(id="composer-fullscreen")
    end
  end
end
