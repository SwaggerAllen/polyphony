defmodule PolyphonyWeb.CampaignWorldLiveTest do
  @moduledoc "Associating a world bible with a campaign from the campaign view."
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Library, Owner}
  alias Polyphony.Authoring.WorldBible

  setup :register_and_log_in_user

  defp campaign(user, attrs \\ %{}) do
    payload =
      Map.merge(
        %{kind: :campaign, name: "Camp", character_ids: [], bible_id: nil, scenes: []},
        attrs
      )

    Library.put(%{owner: Owner.of(user), kind: "campaign", payload: payload})
  end

  test "the world selector lists the author's bibles and persists a choice", %{
    conn: conn,
    user: user
  } do
    wb =
      Library.put(%{
        owner: Owner.of(user),
        kind: "world_bible",
        payload: %WorldBible{name: "Neon Bay"}
      })

    camp = campaign(user)

    {:ok, view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=world")
    assert html =~ "Neon Bay"
    # Nothing attached: the selector sits on "— none —" and there is no edit link.
    assert html =~ ~r{<option value=""[^>]*>— none —}
    refute html =~ "Edit world"

    view
    |> form("form[phx-change=select_world]", %{bible_id: to_string(wb.id)})
    |> render_change()

    # **Attaching copies** (§2.5b). The campaign holds its own bible, not the library
    # one, because a campaign accumulates world arc and two campaigns cannot write
    # different histories onto one bible. The template stays a template.
    attached = Library.payload(Library.get(camp.id))[:bible_id]
    refute attached == wb.id

    copy = Library.get(attached)
    assert copy.derived_from_id == wb.id
    assert Library.payload(copy).name == "Neon Bay"
    assert Library.copy_count(wb.id) == 1
  end

  test "editing the library world does not reach a campaign already started from it",
       %{conn: conn, user: user} do
    wb =
      Library.put(%{
        owner: Owner.of(user),
        kind: "world_bible",
        payload: %WorldBible{name: "Neon Bay", tone: "Wet neon"}
      })

    camp = campaign(user)
    {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}?tab=world")

    view
    |> form("form[phx-change=select_world]", %{bible_id: to_string(wb.id)})
    |> render_change()

    attached = Library.payload(Library.get(camp.id))[:bible_id]
    {:ok, _} = Library.update_payload(wb.id, %WorldBible{name: "Neon Bay", tone: "Dry heat"})

    # The honest limitation the design states rather than implies away.
    assert Library.payload(Library.get(attached)).tone == "Wet neon"
  end

  test "re-selecting the campaign's own copy does not copy the copy",
       %{conn: conn, user: user} do
    wb =
      Library.put(%{
        owner: Owner.of(user),
        kind: "world_bible",
        payload: %WorldBible{name: "Neon Bay"}
      })

    camp = campaign(user, %{bible_id: wb.id})
    {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}?tab=world")

    view
    |> form("form[phx-change=select_world]", %{bible_id: to_string(wb.id)})
    |> render_change()

    assert Library.payload(Library.get(camp.id))[:bible_id] == wb.id
    assert Library.copy_count(wb.id) == 0
  end

  test "a linked world is shown and can be cleared", %{conn: conn, user: user} do
    wb =
      Library.put(%{
        owner: Owner.of(user),
        kind: "world_bible",
        payload: %WorldBible{name: "Neon Bay"}
      })

    camp = campaign(user, %{bible_id: wb.id})

    {:ok, view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=world")
    assert html =~ ~r/<option value="#{wb.id}"[^>]*selected/

    view |> form("form[phx-change=select_world]", %{bible_id: ""}) |> render_change()
    assert Library.payload(Library.get(camp.id))[:bible_id] == nil
  end

  describe "what the picker offers" do
    # Attaching copies (§2.5b), so every campaign's working copy sits in the same
    # library under the same name as the template it came from. The library's Worlds
    # tab has always filtered those out; this picker never did.
    defp world(user, name),
      do:
        Library.put(%{
          owner: Owner.of(user),
          kind: "world_bible",
          payload: %WorldBible{name: name}
        })

    defp options(html) do
      case Regex.run(~r|<select id="bible-select".*?</select>|s, html) do
        [select] -> for [_, id] <- Regex.scan(~r|<option value="(\d+)"|, select), do: id
        nil -> []
      end
    end

    defp attach(conn, camp, id) do
      {:ok, view, _} = live(conn, ~p"/campaigns/#{camp.id}?tab=world")

      view
      |> form("form[phx-change=select_world]", %{bible_id: to_string(id)})
      |> render_change()

      Library.payload(Library.get(camp.id))[:bible_id]
    end

    test "another campaign's working copy is not a template", %{conn: conn, user: user} do
      src = world(user, "Saltmarch")
      first = campaign(user)
      second = campaign(user)

      attach(conn, first, src.id)

      {:ok, _view, html} = live(conn, ~p"/campaigns/#{second.id}?tab=world")

      # Two identically-named "Saltmarch" options with nothing to tell them apart, and
      # picking the wrong one takes a copy of the *played* world, arc and all.
      assert options(html) == [to_string(src.id)]
    end

    test "a trashed campaign's world stops being offered, rather than starting to be",
         %{conn: conn, user: user} do
      src = world(user, "Saltmarch")
      first = campaign(user)
      second = campaign(user)

      copy = attach(conn, first, src.id)
      {:ok, _} = Library.soft_delete(first.id)

      # The bug as reported. A trashed campaign is invisible to `list_for_owner`, so its
      # copy stopped looking attached the moment its campaign went in the bin — and
      # reappeared in every other campaign's picker as though it were a template.
      {:ok, _view, html} = live(conn, ~p"/campaigns/#{second.id}?tab=world")

      refute to_string(copy) in options(html)
      assert options(html) == [to_string(src.id)]
    end

    test "an archived campaign's world is the same case", %{conn: conn, user: user} do
      src = world(user, "Saltmarch")
      first = campaign(user)
      second = campaign(user)

      copy = attach(conn, first, src.id)
      {:ok, _} = Library.archive(first.id)

      {:ok, _view, html} = live(conn, ~p"/campaigns/#{second.id}?tab=world")
      refute to_string(copy) in options(html)
    end

    test "a campaign's own copy stays selectable, so it can still be swapped away from",
         %{conn: conn, user: user} do
      src = world(user, "Saltmarch")
      other = world(user, "Low Water")
      camp = campaign(user)

      copy = attach(conn, camp, src.id)

      {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=world")

      # Its own copy is the selected option — hiding it would leave the picker showing
      # "— none —" over an attached world.
      assert to_string(copy) in options(html)
      assert to_string(other.id) in options(html)
    end
  end

  test "a world can be written from here, and lands attached", %{conn: conn, user: user} do
    camp = campaign(user)
    {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}?tab=world")

    assert {:error, {:live_redirect, %{to: to}}} =
             view |> element("button[phx-click=new_world]") |> render_click()

    id = Library.payload(Library.get(camp.id))[:bible_id]
    assert id
    assert to == "/authoring/bible/#{id}"

    # Written *into* the campaign, so it is already this campaign's own copy — the
    # copy-on-attach step exists to stop two campaigns sharing a bible, and there is
    # nothing here to copy from.
    entry = Library.get(id)
    assert entry.kind == "world_bible"
    assert is_nil(entry.derived_from_id)
    # Blank rather than "New world": a blank name can't clash with an existing one.
    assert Library.payload(entry).name == ""
  end
end
