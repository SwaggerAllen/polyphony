defmodule PolyphonyWeb.WhoLiveTest do
  @moduledoc """
  Tapping a name in the transcript to find out who that is.

  A transcript names people and shows nothing about them, which is fine on the fourth
  scene and useless on the first: a reader meets six names in two pages and had no way
  to ask who any of them are without leaving the story.

  It shows the **cover** and nothing else from the sheet, and that is the design rather
  than a first cut. The cover already *is* this thing — the codebase says so in five
  places, *"the only part strangers see"* — and it is written from everything including
  the secrets, under instruction to give none of them away (§2.12), with a leaked draft
  refused rather than shown. Premise, backstory and facts are the author's working
  material, concealed per-item, and a panel that had to filter them would be a second
  implementation of a guarantee `Visibility` already owns.

  So there is no viewer parameter, and that is the load-bearing part: the author, a
  character mid-scene and a stranger reading a published campaign get the same card.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{App, Library}
  alias Polyphony.Owner
  alias Polyphony.Authoring.CharacterSheet
  alias Polyphony.Authoring.CharacterSheet.Fact
  alias Polyphony.Commands.{CommitPacket, EnterCharacter, OpenScene}
  alias Polyphony.TurnPacket

  setup :register_and_log_in_user

  @sheet %CharacterSheet{
    name: "Wren",
    status: :full,
    pronouns: "she / her",
    cover: "A harbour-master who counts everything twice.",
    premise: "She is skimming the manifests.",
    backstory: "Her father kept the same books.",
    facts: [
      %Fact{statement: "She burned the second page.", concealed: true},
      %Fact{statement: "She reads a manifest upside down.", concealed: false}
    ]
  }

  defp scene_with_wren(user) do
    wren = Library.put(%{owner: Owner.of(user), kind: "character", payload: @sheet})

    id = "who-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: id, opened_beat: 0})
    :ok = App.dispatch(%EnterCharacter{scene_id: id, character_id: to_string(wren.id), beat: 1})

    :ok =
      App.dispatch(%CommitPacket{
        scene_id: id,
        packet_id: "#{id}-1-#{wren.id}",
        character_id: to_string(wren.id),
        beat: 1,
        packet: %TurnPacket{
          moves: [%TurnPacket.Move{seq: 1, type: :speech, content: "Bring it over."}]
        }
      })

    %{scene: id, wren: wren}
  end

  describe "in play" do
    test "the name opens the card", %{conn: conn, user: user} do
      %{scene: scene, wren: wren} = scene_with_wren(user)

      {:ok, view, html} = live(conn, ~p"/play/#{scene}")
      refute html =~ ~s(aria-modal="true")

      html = render_click(view, "who", %{"id" => to_string(wren.id)})

      assert html =~ ~s(aria-modal="true" aria-label="About Wren")
      assert html =~ "A harbour-master who counts everything twice."
      assert html =~ "she / her"
    end

    test "the name is a control, and says what it is for", %{conn: conn, user: user} do
      %{scene: scene, wren: wren} = scene_with_wren(user)
      {:ok, _view, html} = live(conn, ~p"/play/#{scene}")

      assert html =~ ~s(phx-click="who" phx-value-id="#{wren.id}")
      assert html =~ ~s(aria-label="About Wren")
    end

    test "the author gets the public read too, not their own notes",
         %{conn: conn, user: user} do
      %{scene: scene, wren: wren} = scene_with_wren(user)

      {:ok, view, _html} = live(conn, ~p"/play/#{scene}")
      html = render_click(view, "who", %{"id" => to_string(wren.id)})

      # One card for everybody. A per-viewer version would be a second implementation of
      # a guarantee `Visibility` already owns — and the first thing it would get wrong
      # is a concealed fact on the author's screen while a character is shoulder-reading.
      refute html =~ "She is skimming the manifests."
      refute html =~ "Her father kept the same books."
      refute html =~ "She burned the second page."
      refute html =~ "She reads a manifest upside down."
    end

    test "closes, and somebody with nothing written says so", %{conn: conn, user: user} do
      %{scene: scene, wren: wren} = scene_with_wren(user)

      {:ok, view, _html} = live(conn, ~p"/play/#{scene}")
      render_click(view, "who", %{"id" => to_string(wren.id)})
      refute render_click(view, "close_who", %{}) =~ ~s(aria-modal="true")

      bare =
        Library.put(%{
          owner: Owner.of(user),
          kind: "character",
          payload: %CharacterSheet{name: "The bellman", status: :full}
        })

      html = render_click(view, "who", %{"id" => to_string(bare.id)})

      # An honest absence: nothing is being withheld, nobody has written the part a
      # stranger reads.
      assert html =~ "Nothing written about them yet"
      assert html =~ "still blank"
    end

    test "an id that resolves to nothing says so rather than opening an empty card",
         %{conn: conn, user: user} do
      %{scene: scene} = scene_with_wren(user)

      {:ok, view, _html} = live(conn, ~p"/play/#{scene}")
      html = render_click(view, "who", %{"id" => "999999999"})

      refute html =~ ~s(aria-modal="true")
      assert html =~ "Nothing written about them yet."
    end
  end
end
