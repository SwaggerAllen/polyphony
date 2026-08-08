defmodule PolyphonyWeb.AutosaveLiveTest do
  @moduledoc """
  The editors write as you go, so there is nothing to lose by leaving.

  The reported problem: navigate away for a while, come back, and everything on the
  page is gone. Nothing had broken — the edits lived in the LiveView's assigns and were
  written only when Save was pressed, so a backgrounded phone tab took an afternoon's
  writing with it when its socket closed.

  What's pinned here is that the concept of unsaved work is gone, **and** that the
  timer didn't inherit the decisions that belong to a person. A save is not one act any
  more: writing the fields is automatic, while seeding stubs, promoting a stub to a
  castable character, and spending a provider call on reciprocals stay on the button.
  Those are things an author chooses, and a timer would be choosing them every couple of
  seconds while they were still mid-sentence.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Groups, Library}
  alias Polyphony.Owner
  alias Polyphony.Authoring.{CharacterSheet, Group, WorldBible}
  alias Polyphony.Authoring.CharacterSheet.Relationship

  setup :register_and_log_in_user

  setup do
    previous = Application.get_env(:polyphony, :llm)
    Application.put_env(:polyphony, :llm, provider: Polyphony.LLM.Mock)
    on_exit(fn -> Application.put_env(:polyphony, :llm, previous) end)
    :ok
  end

  defp payload_of(entry), do: Library.payload(Library.get(entry.id))

  defp character(user, sheet),
    do: Library.put(%{owner: Owner.of(user), kind: "character", payload: sheet})

  defp world(user, bible),
    do: Library.put(%{owner: Owner.of(user), kind: "world_bible", payload: bible})

  # The scheduled write, driven rather than waited for. One test below does wait, so the
  # timer itself is proved once instead of in every case.
  defp tick(view) do
    send(view.pid, :autosave)
    render(view)
  end

  describe "a world bible" do
    test "writes what was typed without anyone pressing Save", %{conn: conn, user: user} do
      entry = world(user, %WorldBible{name: "Saltmarch"})
      {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")

      view
      |> form("#bible-form", %{name: "Saltmarch", b_setting: ["A port town on a tidal flat."]})
      |> render_change()

      # Nothing yet — a write per keystroke would make a paragraph forty versions.
      assert payload_of(entry).setting in [nil, ""]

      tick(view)

      assert payload_of(entry).setting =~ "A port town on a tidal flat."
    end

    test "the timer really fires, not just the handler", %{conn: conn, user: user} do
      entry = world(user, %WorldBible{name: "Saltmarch"})
      {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")

      view
      |> form("#bible-form", %{name: "Saltmarch", b_tone: ["Damp, close, quietly criminal."]})
      |> render_change()

      # Everything else here drives `:autosave` directly; this one waits out the real
      # quiet period, so the scheduling is proved rather than assumed.
      assert eventually(fn -> payload_of(entry).tone =~ "quietly criminal" end)
    end

    test "a name clash holds the name back and keeps the prose", %{conn: conn, user: user} do
      world(user, %WorldBible{name: "Saltmarch"})
      entry = world(user, %WorldBible{name: "Low Water"})

      {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")

      view
      |> form("#bible-form", %{name: "Saltmarch", b_setting: ["Half of it underwater."]})
      |> render_change()

      html = tick(view)

      # Refusing the whole sheet over a label would mean the autosave discarding the
      # writing it exists to protect.
      saved = payload_of(entry)
      assert saved.setting =~ "Half of it underwater."
      assert saved.name == "Low Water"

      # And it says so at the field, without a flash — nobody pressed anything.
      assert html =~ "You already have a world called Saltmarch"
      refute html =~ "Not saved under that name"
    end
  end

  describe "a character sheet" do
    test "writes what was typed", %{conn: conn, user: user} do
      entry = character(user, %CharacterSheet{name: "Wren", status: :full})
      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

      view
      |> form("#sheet-form", %{name: "Wren Ashgrove", b_premise: ["She signs for cargo."]})
      |> render_change()

      tick(view)

      saved = payload_of(entry)
      assert saved.name == "Wren Ashgrove"
      assert saved.premise =~ "She signs for cargo."
    end

    test "does not promote a stub — that is Save's to do", %{conn: conn, user: user} do
      entry = character(user, %CharacterSheet{name: "Wren", status: :stub})
      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

      view
      |> form("#sheet-form", %{name: "Wren", b_premise: ["Half a thought."]})
      |> render_change()

      tick(view)

      # `SceneControl` refuses a non-`:full` character, so promotion is the moment a
      # half-written sheet becomes something that can walk into a scene. It has to mean
      # the author said so, not that a key was pressed.
      assert payload_of(entry).status == :stub
      assert payload_of(entry).premise =~ "Half a thought."

      view |> form("#sheet-form", %{name: "Wren"}) |> render_submit()
      assert payload_of(entry).status == :full
    end

    test "does not write new people into the library", %{conn: conn, user: user} do
      entry =
        character(user, %CharacterSheet{
          name: "Wren",
          status: :full,
          relationships: [%Relationship{target: "The bellman", descriptor: "owes her"}]
        })

      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

      before = length(Library.list_for_owner(Owner.of(user)))
      view |> form("#sheet-form", %{name: "Wren"}) |> render_change()
      tick(view)

      # Seeding a stub creates a person. Doing that on a timer means every half-typed
      # name in a relationship field becomes a character in the library.
      assert length(Library.list_for_owner(Owner.of(user))) == before

      view |> form("#sheet-form", %{name: "Wren"}) |> render_submit()
      assert length(Library.list_for_owner(Owner.of(user))) > before
    end
  end

  describe "a group" do
    test "writes what was typed", %{conn: conn, user: user} do
      entry = Groups.create(Owner.of(user), %Group{name: "The Tidewatch", campaign_id: "camp"})
      {:ok, view, _html} = live(conn, ~p"/authoring/group/#{entry.id}")

      view
      |> form("#group-form", %{name: "The Tidewatch", b_premise: ["Half constabulary."]})
      |> render_change()

      tick(view)

      assert payload_of(entry).premise =~ "Half constabulary."
    end
  end

  describe "leaving the page" do
    test "the last edit is written on the way out", %{conn: conn, user: user} do
      entry = world(user, %WorldBible{name: "Saltmarch"})
      {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")

      view
      |> form("#bible-form", %{name: "Saltmarch", b_setting: ["Written on the way out."]})
      |> render_change()

      # Closing the tab is the exact case this exists for, and the pending timer would
      # go with the process. `terminate/2` is the last chance to write.
      #
      # `LiveViewTest` links the view to the test, so trap the exit rather than take it.
      Process.flag(:trap_exit, true)
      ref = Process.monitor(view.pid)
      GenServer.stop(view.pid, :shutdown)
      assert_receive {:DOWN, ^ref, :process, _, _}, 2_000

      assert payload_of(entry).setting =~ "Written on the way out."
    end
  end

  describe "a generation you walked away from" do
    test "is applied when you come back, not thrown away", %{conn: conn, user: user} do
      entry = world(user, %WorldBible{name: "Saltmarch"})

      {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")

      view
      |> element("button[phx-click=generate_field][phx-value-field=setting]")
      |> render_click()

      # Leave while it's running — the exact thing that used to kill the task and throw
      # the answer away, having already paid for it.
      Process.flag(:trap_exit, true)
      ref = Process.monitor(view.pid)
      GenServer.stop(view.pid, :shutdown)
      assert_receive {:DOWN, ^ref, :process, _, _}, 2_000

      Oban.drain_queue(queue: :generation)

      # Come back. The answer was waiting, and lands in the field exactly as it would
      # have if the tab had stayed open — then autosaves like any other edit.
      {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")
      tick(view)

      assert Library.payload(Library.get(entry.id)).setting not in [nil, ""]
    end

    test "still shows as running if it hasn't finished", %{conn: conn, user: user} do
      entry = world(user, %WorldBible{name: "Saltmarch"})

      {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")

      view
      |> element("button[phx-click=generate_field][phx-value-field=setting]")
      |> render_click()

      # A fresh mount with the job still enqueued: the spinner comes back from the row,
      # because a control that looks idle while its work is in flight invites a second
      # press and a second bill.
      {:ok, _view, html} = live(conn, ~p"/authoring/bible/#{entry.id}")
      assert html =~ "✦ …"
    end
  end

  defp eventually(fun, remaining \\ 3_000)
  defp eventually(_fun, remaining) when remaining <= 0, do: false

  defp eventually(fun, remaining) do
    if truthy?(fun) do
      true
    else
      Process.sleep(100)
      eventually(fun, remaining - 100)
    end
  end

  # The predicate reads a field that is nil until the write lands, so `=~` raises
  # rather than returning false until then.
  defp truthy?(fun) do
    !!fun.()
  rescue
    _ -> false
  end
end
