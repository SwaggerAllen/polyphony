defmodule PolyphonyWeb.AudiencePickerLiveTest do
  @moduledoc """
  The audience picker on the two surfaces that carry secrets today.

  It is **one component with two headers** — the design's own reason for drawing it
  in its own file — so what's pinned here is that both surfaces reach the same one and
  store the same shape, and that what the picker sets actually reaches the character's
  context. A control that writes data nothing reads is worse than no control.

  Reachability is the other half: nothing appears until an item is marked secret.
  Secret first, audience second.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Groups, Library}
  alias Polyphony.Owner
  alias Polyphony.Authoring.{Audience, CharacterSheet, Group, WorldBible}
  alias Polyphony.Authoring.CharacterSheet.Fact
  alias Polyphony.Authoring.WorldBible.Entry

  @bell "The tide bell answers to something under the flats."
  @kestrel "She's been signing for the Kestrel's cargo since March."

  # Apostrophes come back HTML-escaped, so assertions that span one match the escaped
  # form. `escaped/1` keeps the fixtures written the way a person would write them.
  defp escaped(text), do: String.replace(text, "'", "&#39;")

  setup :register_and_log_in_user

  setup do
    previous = Application.get_env(:polyphony, :llm)
    Application.put_env(:polyphony, :llm, provider: Polyphony.LLM.Mock)
    on_exit(fn -> Application.put_env(:polyphony, :llm, previous) end)
    :ok
  end

  defp character(user, sheet),
    do: Library.put(%{owner: Owner.of(user), kind: "character", payload: sheet})

  defp world(user, bible),
    do: Library.put(%{owner: Owner.of(user), kind: "world_bible", payload: bible})

  defp payload_of(entry), do: Library.payload(Library.get(entry.id))

  describe "on a world bible entry" do
    setup %{user: user} do
      sable = character(user, %CharacterSheet{name: "Sable Quist"})
      group = Groups.create(Owner.of(user), %Group{name: "The Tidewatch", campaign_id: "camp"})
      {:ok, _} = Groups.add_member(group.id, sable.id)

      entry =
        world(user, %WorldBible{
          name: "Saltmarch",
          starting_canon: [%Entry{statement: @bell, concealed: true}]
        })

      %{entry: entry, group: group, sable: sable}
    end

    test "is reachable only from a secret", %{conn: conn, user: user} do
      public =
        world(user, %WorldBible{name: "Low Water", starting_canon: [%Entry{statement: @bell}]})

      {:ok, _view, html} = live(conn, ~p"/authoring/bible/#{public.id}")
      refute html =~ ~s(phx-click="open_audience")
    end

    test "a group ticked in it persists, and reads back on the item's own line",
         %{conn: conn, entry: entry, group: group} do
      {:ok, view, html} = live(conn, ~p"/authoring/bible/#{entry.id}")
      assert html =~ "Secret · nobody knows"

      view
      |> element("button[phx-click=open_audience][phx-value-field=starting_canon]")
      |> render_click()

      html =
        view
        |> element("button[phx-click=toggle_audience][phx-value-id='#{group.id}']")
        |> render_click()

      assert html =~ "Secret · The Tidewatch knows"

      view |> form("form[phx-submit=save]", %{name: "Saltmarch"}) |> render_submit()

      assert [%Entry{audience: %Audience{group_ids: [gid]}}] =
               payload_of(entry).starting_canon

      assert gid == to_string(group.id)
    end

    test "the resolved line says who that means right now, not who it meant when written",
         %{conn: conn, user: user, entry: entry, group: group} do
      {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")

      view
      |> element("button[phx-click=open_audience][phx-value-field=starting_canon]")
      |> render_click()

      html =
        view
        |> element("button[phx-click=toggle_audience][phx-value-id='#{group.id}']")
        |> render_click()

      assert html =~ escaped("Right now that's 1 person")
      assert html =~ "will know it too"

      view |> form("form[phx-submit=save]", %{name: "Saltmarch"}) |> render_submit()

      # Someone else joins the group; re-opening reflects it without touching the secret.
      bellman = character(user, %CharacterSheet{name: "The bellman"})
      {:ok, _} = Groups.add_member(group.id, bellman.id)

      {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")

      html =
        view
        |> element("button[phx-click=open_audience][phx-value-field=starting_canon]")
        |> render_click()

      assert html =~ escaped("Right now that's 2 people")
    end

    test "what it sets reaches the character's prompt, and nobody else's",
         %{conn: conn, user: user, entry: entry, group: group, sable: sable} do
      {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")

      view
      |> element("button[phx-click=open_audience][phx-value-field=starting_canon]")
      |> render_click()

      view
      |> element("button[phx-click=toggle_audience][phx-value-id='#{group.id}']")
      |> render_click()

      view |> form("form[phx-submit=save]", %{name: "Saltmarch"}) |> render_submit()

      bible = payload_of(entry)
      outsider = character(user, %CharacterSheet{name: "Wren"})

      assert prefix_for(sable.id, bible) =~ @bell
      refute prefix_for(outsider.id, bible) =~ @bell
    end

    defp prefix_for(character_id, bible) do
      Polyphony.Context.materialize(%{
        scene_id: "S1",
        character_id: to_string(character_id),
        sheet: %CharacterSheet{name: "X"},
        world_bible: bible
      }).prefix
    end
  end

  describe "on a character's fact" do
    test "the owner is locked on rather than offered as a choice", %{conn: conn, user: user} do
      character(user, %CharacterSheet{name: "Sable Quist"})

      wren =
        character(user, %CharacterSheet{
          name: "Wren Ashgrove",
          facts: [%Fact{statement: @kestrel, concealed: true}]
        })

      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{wren.id}")

      html =
        view |> element("button[phx-click=open_audience][phx-value-index='0']") |> render_click()

      assert html =~ escaped("it's theirs")
      assert html =~ "Wren Ashgrove"
      # She isn't in the tickable list — she is the owner row.
      refute html =~
               ~s(phx-click="toggle_audience" phx-value-kind="character" phx-value-id="#{wren.id}")
    end

    test "naming someone persists and reaches them, without reaching anyone else",
         %{conn: conn, user: user} do
      sable = character(user, %CharacterSheet{name: "Sable Quist"})
      ilias = character(user, %CharacterSheet{name: "Ilias Vane"})

      wren =
        character(user, %CharacterSheet{
          name: "Wren Ashgrove",
          facts: [%Fact{statement: @kestrel, concealed: true}]
        })

      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{wren.id}")
      view |> element("button[phx-click=open_audience][phx-value-index='0']") |> render_click()

      view
      |> element("button[phx-click=toggle_audience][phx-value-id='#{sable.id}']")
      |> render_click()

      view |> form("form[phx-submit=save]", %{name: "Wren Ashgrove"}) |> render_submit()

      assert [%Fact{audience: %Audience{character_ids: [cid]}}] = payload_of(wren).facts
      assert cid == to_string(sable.id)

      cast = [{to_string(wren.id), payload_of(wren)}]

      assert context_prefix(sable.id, cast) =~ @kestrel
      refute context_prefix(ilias.id, cast) =~ @kestrel
    end

    defp context_prefix(character_id, cast) do
      Polyphony.Context.materialize(%{
        scene_id: "S1",
        character_id: to_string(character_id),
        sheet: %CharacterSheet{name: "X"},
        cast: cast
      }).prefix
    end
  end

  describe "as an overlay" do
    setup %{user: user} do
      wren =
        character(user, %CharacterSheet{
          name: "Wren Ashgrove",
          facts: [%Fact{statement: @kestrel, concealed: true}]
        })

      %{wren: wren}
    end

    defp open(view),
      do:
        view |> element("button[phx-click=open_audience][phx-value-index='0']") |> render_click()

    test "it draws over the page rather than further down it", %{conn: conn, wren: wren} do
      {:ok, view, html} = live(conn, ~p"/authoring/character/#{wren.id}")
      refute html =~ ~s(class="scrim")

      html = open(view)

      # The whole point: opened from a control halfway down a long sheet, an inline
      # panel lands off-screen and reads as nothing having happened.
      assert html =~ ~s(class="scrim")
      assert html =~ ~s(class="overlay")
      assert html =~ "sheet modal"
      assert html =~ ~s(role="dialog")
      assert html =~ ~s(aria-modal="true")
    end

    test "the scrim is a way out, and so is Escape", %{conn: conn, wren: wren} do
      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{wren.id}")

      open(view)
      html = view |> element(".scrim") |> render_click()
      refute html =~ "Who starts out knowing"

      open(view)
      html = view |> element(".overlay") |> render_keyup(%{"key" => "Escape"})
      refute html =~ "Who starts out knowing"
    end

    test "and so is the control in its head, which says what it does", %{conn: conn, wren: wren} do
      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{wren.id}")

      html = open(view)
      # "Done" rather than a ×: the ticks apply as you make them, so there is nothing
      # to confirm and nothing to cancel — the only question is whether you're finished.
      assert html =~ "Done"

      html =
        view
        |> element("button[phx-click=close_audience]", "Done")
        |> render_click()

      refute html =~ "Who starts out knowing"
    end

    test "the way out and the count stay put while the list scrolls",
         %{conn: conn, user: user, wren: wren} do
      character(user, %CharacterSheet{name: "Sable Quist"})

      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{wren.id}")
      open(view)

      # Only the middle scrolls. A close you have to scroll to find is not a close,
      # and a resolved count you can't see while ticking isn't the honesty check —
      # so the list is what's inside `.modal-body`, and neither of those two is.
      assert has_element?(view, ".modal-body button[phx-click=toggle_audience]")
      refute has_element?(view, ".modal-body button[phx-click=close_audience]")
      refute has_element?(view, ".modal-body .dot[style*='--secret']")
    end
  end

  describe "the read-back on a character's sheet" do
    test "shows what they start out knowing, and says how they came by it",
         %{conn: conn, user: user} do
      sable = character(user, %CharacterSheet{name: "Sable Quist"})
      group = Groups.create(Owner.of(user), %Group{name: "The Tidewatch", campaign_id: "camp"})
      {:ok, _} = Groups.add_member(group.id, sable.id)

      character(user, %CharacterSheet{
        name: "Wren Ashgrove",
        facts: [
          %Fact{
            statement: @kestrel,
            concealed: true,
            audience: Audience.add_character(Audience.empty(), sable.id)
          }
        ]
      })

      world(user, %WorldBible{
        name: "Saltmarch",
        starting_canon: [
          %Entry{
            statement: @bell,
            concealed: true,
            audience: Audience.add_group(Audience.empty(), group.id)
          }
        ]
      })

      {:ok, _view, html} = live(conn, ~p"/authoring/character/#{sable.id}")

      assert html =~ "What they start out knowing"
      assert html =~ escaped(@kestrel)
      assert html =~ "From Wren Ashgrove · you named them"
      assert html =~ @bell
      assert html =~ escaped("From Saltmarch · they're in a group")
      # Read-only: it says where to go rather than offering an edit here.
      assert html =~ "change it where the secret lives"
    end

    test "someone in the dark gets no section at all", %{conn: conn, user: user} do
      character(user, %CharacterSheet{
        name: "Wren",
        facts: [%Fact{statement: @kestrel, concealed: true}]
      })

      ilias = character(user, %CharacterSheet{name: "Ilias Vane"})

      {:ok, _view, html} = live(conn, ~p"/authoring/character/#{ilias.id}")
      refute html =~ "What they start out knowing"
    end
  end
end
