defmodule PolyphonyWeb.PlayDraftsLiveTest do
  @moduledoc """
  Assisted control (§A2): a generated turn the author takes or discards.

  The backend has been able to accept and discard drafts since §1.5 shipped; the card
  was deferred and never built. The visible effect was that setting a character to
  draft-and-approve made Continue do nothing you could see — the beat stopped, the
  turn sat in a table, and no screen mentioned it in any perspective.

  The guarantee underneath: **a draft is not fiction.** It never reaches the log, so
  it can't reach anyone's projection, which is exactly why it can be shown to a
  character's view without a visibility decision — and why its announcement rides its
  own topic rather than the omniscient one.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{App, Drafts}
  alias Polyphony.Commands.{DeclareTurnOrder, EnterCharacter, OpenScene}
  alias Polyphony.Director.BeatOps
  alias PolyphonyCore.Director.Commands.OpenBeat
  alias Polyphony.TurnPacket
  alias Polyphony.TurnPacket.Move

  setup :register_and_log_in_user

  defp scene_with(chars) do
    scene = "draft-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})

    for c <- chars,
        do: :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: c, beat: 1})

    # The beat aggregate has to be open for a decision to land on it — accepting
    # records a packet against it, discarding records a pass. In the app this is
    # what Continue does before the Director walks the order at all, so a draft can
    # only ever exist on a beat that has one.
    :ok = App.dispatch(%DeclareTurnOrder{scene_id: scene, beat: 1, order: chars})

    :ok =
      App.dispatch(%OpenBeat{
        beat_ref: BeatOps.beat_ref(scene, 1),
        scene_id: scene,
        beat: 1,
        cast: chars
      })

    scene
  end

  defp packet do
    %TurnPacket{
      moves: [
        %Move{seq: 1, type: :thought, content: "The bell rang twice."},
        %Move{seq: 2, type: :speech, content: "Nobody rings it twice.", addressed_to: []}
      ]
    }
  end

  defp draft(scene, character \\ "mira", beat \\ 1),
    do: Drafts.draft(scene, character, beat, packet(), source: "assisted")

  test "a pending draft is on screen, in full, with both decisions", %{conn: conn} do
    scene = scene_with(["mira"])
    draft(scene)

    {:ok, _view, html} = live(conn, ~p"/play/#{scene}")

    # The turn itself, not a notice that one exists: approving is looking at the thing.
    assert html =~ "Nobody rings it twice."
    assert html =~ "The bell rang twice."
    assert html =~ "Waiting on you"
    assert html =~ ~s(phx-click="accept_draft")
    assert html =~ ~s(phx-click="discard_draft")
  end

  test "and shows through the character's own eyes too", %{conn: conn} do
    # The complaint that started this: navigating to the controlled character didn't
    # surface it either. A draft has never touched the log, so there is no projection
    # to filter it out of — and the person deciding is the author whichever pair of
    # eyes they have borrowed.
    scene = scene_with(["mira"])
    draft(scene)

    {:ok, _view, html} = live(conn, ~p"/play/#{scene}?as=mira")

    assert html =~ "Nobody rings it twice."
    assert html =~ ~s(phx-click="accept_draft")
  end

  test "taking it commits the turn and clears the card", %{conn: conn} do
    scene = scene_with(["mira"])
    row = draft(scene)

    {:ok, view, _html} = live(conn, ~p"/play/#{scene}")

    html =
      view
      |> element(~s(button[phx-click="accept_draft"][phx-value-id="#{row.id}"]))
      |> render_click()

    # It is fiction now: in the transcript, not in a card.
    refute html =~ "Waiting on you"
    assert html =~ "Nobody rings it twice."
    assert Drafts.get(row.id).status == "accepted"
  end

  test "discarding is a pass, and says so", %{conn: conn} do
    scene = scene_with(["mira"])
    row = draft(scene)

    {:ok, view, _html} = live(conn, ~p"/play/#{scene}")

    # The wording matters: the backend records a pass, so "discard" on its own would
    # read as "try again" when the slot has actually given up its turn.
    assert render(view) =~ "Discard — they pass"

    html =
      view
      |> element(~s(button[phx-click="discard_draft"][phx-value-id="#{row.id}"]))
      |> render_click()

    refute html =~ "Waiting on you"
    refute html =~ "Nobody rings it twice."
    assert Drafts.get(row.id).status == "discarded"
  end

  test "an announcement reaches an open screen without a reload", %{conn: conn} do
    scene = scene_with(["mira"])
    {:ok, view, html} = live(conn, ~p"/play/#{scene}")
    refute html =~ "Waiting on you"

    # `Drafts.draft/5` broadcasts; the view is subscribed to the workflow topic.
    draft(scene)

    assert render(view) =~ "Waiting on you"
  end

  test "the workflow topic carries no fiction, which is what lets a character hear it" do
    scene = scene_with(["mira"])
    Phoenix.PubSub.subscribe(Polyphony.PubSub, Drafts.topic(scene))

    draft(scene)

    assert_receive {:polyphony_event, event}
    assert event.type == "draft.ready"

    # The announcement names the draft, never its contents. Subscribing a character's
    # view to the omniscient projection to catch this instead would have handed it
    # every other character's turns.
    refute Map.has_key?(event, :packet)
    refute Map.has_key?(event, :moves)
  end

  test "a nearly-right turn can be corrected before it is taken", %{conn: conn} do
    scene = scene_with(["mira"])
    row = draft(scene)

    {:ok, view, _html} = live(conn, ~p"/play/#{scene}")

    # `Drafts.edit/3` has always been able to do this and nothing called it, so the
    # card could only take a turn whole or throw it away — and nearly-right is the
    # ordinary case, which is the whole argument for approving one at all.
    view
    |> element(~s(button[phx-click="edit_draft"][phx-value-id="#{row.id}"]))
    |> render_click()

    view
    |> form(~s(form[phx-submit="save_draft_edit"]), %{
      draft_id: to_string(row.id),
      text: "Nobody rings it three times."
    })
    |> render_submit()

    # Corrected in place and still pending — editing is not accepting.
    assert Drafts.get(row.id).status == "pending"
    assert Drafts.get(row.id).edited
    assert render(view) =~ "Nobody rings it three times."
    assert render(view) =~ "Waiting on you"

    # And taking it commits what the author wrote, not what the model did.
    view
    |> element(~s(button[phx-click="accept_draft"][phx-value-id="#{row.id}"]))
    |> render_click()

    html = render(view)
    assert html =~ "Nobody rings it three times."
    refute html =~ "Nobody rings it twice."
  end

  test "with nothing pending there is no card", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/play/#{scene_with(["mira"])}")

    refute html =~ "Waiting on you"
    refute html =~ ~s(phx-click="accept_draft")
  end
end
