defmodule PolyphonyWeb.PlayIntrosPanelLiveTest do
  @moduledoc """
  The introductions panel's **own two doors** (§07) — write someone new, and find
  someone you've written — plus what happens to a character who is in the room before
  their sheet is.

  The three doors all end in a full character; what differs is only how long the sheet
  takes to arrive. Writing somebody new inverts the order the cast menu's *write in*
  uses — they enter **first** and the sheet lands underneath them — because the entrance
  is what the room reacts to. That inversion is what `admitted_writing` and
  `admitted_failed` exist to hold, and what these tests pin.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{App, Library}
  alias Polyphony.Owner
  alias Polyphony.Authoring.CharacterSheet
  alias PolyphonyCore.Commands.{EnterCharacter, OpenScene}
  alias PolyphonyCore.Events.{CharacterEntered, CharacterExited, WorldEventOccurred}

  setup :register_and_log_in_user

  setup do
    previous = Application.get_env(:polyphony, :llm)
    Application.put_env(:polyphony, :llm, provider: Polyphony.LLM.Mock)
    on_exit(fn -> Application.put_env(:polyphony, :llm, previous) end)
    :ok
  end

  defp character(user, name, status \\ :full, attrs \\ %{}) do
    sheet = struct(%CharacterSheet{name: name, status: status}, attrs)
    Library.put(%{owner: Owner.of(user), kind: "character", payload: sheet})
  end

  defp campaign(user, ids),
    do:
      Library.put(%{
        owner: Owner.of(user),
        kind: "campaign",
        payload: %{kind: :campaign, name: "Camp", character_ids: ids, bible_id: nil, scenes: []}
      })

  defp scene(campaign_id, present) do
    id = "intros-panel-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: id, opened_beat: 0, campaign_id: campaign_id})

    for c <- present,
        do:
          :ok =
            App.dispatch(%EnterCharacter{scene_id: id, character_id: to_string(c.id), beat: 1})

    id
  end

  defp events(scene_id),
    do: App |> Commanded.EventStore.stream_forward(scene_id) |> Enum.map(& &1.data)

  defp members(scene_id),
    do: for(%CharacterEntered{character_id: c} <- events(scene_id), do: c)

  defp open_panel(view),
    do: view |> element("button[phx-click=toggle_intros]") |> render_click()

  # A scene with one person in it and the panel open. There is no Director proposal, so
  # this is `intros_no_suggestion` — the state that makes the panel's own doors
  # load-bearing rather than a fallback.
  defp opened(conn, user, extra_cast \\ []) do
    wren = character(user, "Wren")
    camp = campaign(user, [wren.id | Enum.map(extra_cast, & &1.id)])
    id = scene(camp.id, [wren])
    {:ok, view, _html} = live(conn, ~p"/play/#{id}")
    {view, id, open_panel(view)}
  end

  test "the panel's doors are there when the Director has nobody to suggest",
       %{conn: conn, user: user} do
    {_view, _id, html} = opened(conn, user)

    assert html =~ "The Director isn&#39;t asking for anyone"
    assert html =~ "Write someone new"
    assert html =~ "Find someone you&#39;ve written"
  end

  describe "write someone new" do
    test "brings them on before the sheet lands, and settles it underneath them",
         %{conn: conn, user: user} do
      {view, id, _html} = opened(conn, user)

      view |> element("button[phx-click=intros_write_new]") |> render_click()

      html =
        view
        |> form("#intro-new", %{name: "The bellman", premise: "He rang it.", control: "assisted"})
        |> render_submit()

      # **In the room already** — the generation hasn't run, and that is the point:
      # the entrance is what the others react to, not the sheet.
      [entry] =
        Enum.filter(Library.list_for_owner(Owner.of(user)), &(char_name(&1) == "The bellman"))

      assert to_string(entry.id) in members(id)
      assert %CharacterSheet{status: :stub} = Library.payload(entry)
      assert html =~ "Here · being written"

      html = generate(view)

      # The sheet arrived underneath them. No second entrance — one `CharacterEntered`,
      # because a second would be `{:error, :already_present}` and a reader who saw them
      # arrive twice would be reading a scene that didn't happen.
      assert %CharacterSheet{status: :full} = Library.payload(Library.get(entry.id))
      assert Enum.count(members(id), &(&1 == to_string(entry.id))) == 1
      refute html =~ "Here · being written"
    end

    test "the premise is the seed the sheet is written from, not decoration",
         %{conn: conn, user: user} do
      {view, _id, _html} = opened(conn, user)

      view |> element("button[phx-click=intros_write_new]") |> render_click()

      view
      |> form("#intro-new", %{name: "The bellman", premise: "He rang it.", control: "autonomous"})
      |> render_submit()

      entry = Enum.find(Library.list_for_owner(Owner.of(user)), &(char_name(&1) == "The bellman"))
      # A stub's `role` is what `Autofill` folds into the generation context, so the
      # sentence typed into play survives into the sheet.
      assert Library.payload(entry).role == "He rang it."
    end

    test "the *they'll be* answer is applied at the moment they arrive",
         %{conn: conn, user: user} do
      {view, id, _html} = opened(conn, user)

      view |> element("button[phx-click=intros_write_new]") |> render_click()

      view
      |> form("#intro-new", %{name: "The bellman", premise: "", control: "user_controlled"})
      |> render_submit()

      entry = Enum.find(Library.list_for_owner(Owner.of(user)), &(char_name(&1) == "The bellman"))

      assert PolyphonyCore.TurnOrder.control_mode(events(id), to_string(entry.id)) ==
               "user_controlled"
    end

    test "a nameless one is refused rather than creating an unnamed character",
         %{conn: conn, user: user} do
      {view, id, _html} = opened(conn, user)

      view |> element("button[phx-click=intros_write_new]") |> render_click()
      html = view |> form("#intro-new", %{name: "  ", premise: "x"}) |> render_submit()

      assert html =~ "Give them a name first."
      assert members(id) |> length() == 1
    end
  end

  describe "when writing them doesn't work" do
    setup do
      # The provider answers, and answers with nothing worth keeping: `StubGen` leaves
      # the sheet a stub, so they are in the room with no sheet — `admitted_failed`.
      Application.put_env(:polyphony, :llm,
        provider: Polyphony.LLM.Stub,
        stub_response: {:ok, "{}"}
      )

      :ok
    end

    test "they stay in the scene, and the panel offers three ways out",
         %{conn: conn, user: user} do
      {_view, id, entry, html} = failed_walkon(conn, user)

      # Distinct from `failed_turn`: this is a character with no sheet standing in a
      # working scene, so they are not removed and the ways out are not a retry with
      # decoration.
      assert to_string(entry.id) in members(id)
      assert html =~ "Here · not written"
      assert html =~ ~s(phx-click="intro_retry")
      assert html =~ ~s(phx-click="intro_write_self")
      assert html =~ ~s(phx-click="send_away_confirm")
    end

    test "try again re-runs the write", %{conn: conn, user: user} do
      {view, _id, entry, _html} = failed_walkon(conn, user)

      # A provider that works this time.
      Application.put_env(:polyphony, :llm, provider: Polyphony.LLM.Mock)

      view
      |> element(~s(button[phx-click="intro_retry"][phx-value-id="#{entry.id}"]))
      |> render_click()

      html = generate(view)

      assert %CharacterSheet{status: :full} = Library.payload(Library.get(entry.id))
      refute html =~ "Here · not written"
    end

    test "sending them away is a departure, not an undo", %{conn: conn, user: user} do
      {view, id, entry, _html} = failed_walkon(conn, user)

      html =
        view
        |> element(~s(button[phx-click="send_away_confirm"][phx-value-id="#{entry.id}"]))
        |> render_click()

      # The confirm names what **survives**, because nothing is destroyed.
      assert html =~ "Their entrance stays in the transcript"

      view
      |> element(~s(button[phx-click="send_away"][phx-value-id="#{entry.id}"]))
      |> render_click()

      log = events(id)

      # The entrance is still on the log — other characters could have reacted to it, so
      # removing them cannot mean erasing it. The fiction absorbs the departure the same
      # way the Director's own rulings do, and then they exit.
      assert to_string(entry.id) in members(id)

      assert Enum.any?(log, fn
               %WorldEventOccurred{content: c} -> c =~ "leaves"
               _ -> false
             end)

      assert Enum.any?(log, fn
               %CharacterExited{character_id: c} -> c == to_string(entry.id)
               _ -> false
             end)

      # The roster is who is here now; the transcript is what happened. Only one of them
      # remembers him — no tombstone, no struck-through row.
      refute render(view) =~ "Here · not written"
    end

    test "and keeping them cancels without touching the log", %{conn: conn, user: user} do
      {view, id, entry, _html} = failed_walkon(conn, user)

      view
      |> element(~s(button[phx-click="send_away_confirm"][phx-value-id="#{entry.id}"]))
      |> render_click()

      html = view |> element("button[phx-click=send_away_cancel]") |> render_click()

      refute Enum.any?(events(id), &match?(%CharacterExited{}, &1))
      assert html =~ "Here · not written"
    end
  end

  describe "find someone you've written" do
    test "reaches the whole campaign roster, including walk-ons", %{conn: conn, user: user} do
      walkon = character(user, "The ferryman", :full, %{tier: :incidental})
      _stranger = character(user, "Another campaign's person")
      {view, _id, _html} = opened(conn, user, [walkon])

      html = view |> element("button[phx-click=intros_picker]") |> render_click()

      # The reach it adds over the Director's suggestion is *within* the campaign — the
      # walk-ons it would never propose. Not the author's library: characters do not
      # cross campaigns (§2.7), and this is the one surface tempted to break that.
      assert html =~ "The ferryman"
      refute html =~ "Another campaign&#39;s person"
    end

    test "somebody already in the scene is shown, dimmed and inert",
         %{conn: conn, user: user} do
      {view, _id, _html} = opened(conn, user)

      html = view |> element("button[phx-click=intros_picker]") |> render_click()

      # Showing them costs a row and stops the GM hunting for somebody standing in front
      # of them — so the row is there, and it cannot be clicked.
      assert html =~ "already here"
      refute html =~ ~s(phx-click="picker_choose")
    end

    test "the tier filter is the primary one, because that roster gets long",
         %{conn: conn, user: user} do
      walkon = character(user, "The ferryman", :full, %{tier: :incidental})
      lead = character(user, "Sable", :full, %{tier: :main})
      {view, _id, _html} = opened(conn, user, [walkon, lead])

      view |> element("button[phx-click=intros_picker]") |> render_click()
      html = render_click(view, "picker_tier", %{"tier" => "incidental"})

      assert html =~ "The ferryman"
      refute html =~ "Sable"
    end

    test "no matches offers to write what was searched for", %{conn: conn, user: user} do
      {view, _id, _html} = opened(conn, user)

      view |> element("button[phx-click=intros_picker]") |> render_click()
      html = view |> form("#picker-search", %{q: "alchemist"}) |> render_change()

      assert html =~ "Nobody in this campaign by that name."
      assert html =~ "Write alchemist"

      # And the query carries into the name, rather than making them type it twice.
      html = render_click(view, "intros_write_new", %{"name" => "alchemist"})
      assert html =~ ~s(value="alchemist")
    end

    test "choosing confirms before entering, then brings them on",
         %{conn: conn, user: user} do
      sable = character(user, "Sable", :full, %{premise: "She owns the ferry."})
      {view, id, _html} = opened(conn, user, [sable])

      view |> element("button[phx-click=intros_picker]") |> render_click()

      # A second step rather than one-click entry from the row: enough to catch *wrong
      # Sable* before she walks in.
      html = render_click(view, "picker_choose", %{"id" => to_string(sable.id)})
      assert html =~ "She owns the ferry."
      assert html =~ "Bring them on"
      refute to_string(sable.id) in members(id)

      render_click(view, "intro_control", %{"control" => "assisted"})
      render_click(view, "picker_admit", %{"id" => to_string(sable.id)})

      assert to_string(sable.id) in members(id)
      assert PolyphonyCore.TurnOrder.control_mode(events(id), to_string(sable.id)) == "assisted"
    end
  end

  test "none of the panel is offered to a character viewer", %{conn: conn, user: user} do
    wren = character(user, "Wren")
    camp = campaign(user, [wren.id])
    id = scene(camp.id, [wren])

    {:ok, _view, html} = live(conn, ~p"/play/#{id}?as=#{wren.id}")

    # The panel is author tooling in the strictest sense — it is where the Director's
    # unratified judgements about the scene live. A character seeing it would be a
    # visibility failure with a UI in front of it.
    refute html =~ "toggle_intros"
    refute html =~ "Write someone new"
  end

  # A walk-on written in from the panel whose generation came back with nothing usable.
  defp failed_walkon(conn, user) do
    {view, id, _html} = opened(conn, user)
    view |> element("button[phx-click=intros_write_new]") |> render_click()

    view
    |> form("#intro-new", %{name: "The bellman", premise: "", control: "autonomous"})
    |> render_submit()

    html = generate(view)
    entry = Enum.find(Library.list_for_owner(Owner.of(user)), &(char_name(&1) == "The bellman"))
    {view, id, entry, html}
  end

  defp char_name(entry) do
    case Library.payload(entry) do
      %{name: n} -> n
      _ -> nil
    end
  end
end
