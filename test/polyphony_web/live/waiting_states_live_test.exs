defmodule PolyphonyWeb.WaitingStatesLiveTest do
  @moduledoc """
  What the screen does while a model is writing.

  Both waits here are **seconds**, not milliseconds, and both used to be drawn as
  nothing: on a character sheet the only feedback for "✦ Write every field" was its own
  button going grey while five empty textareas sat there — which is exactly what a
  screen that did nothing looks like — and in play the only sign a turn was coming was a
  sentence in a bar below the transcript, on a first beat where the transcript itself
  said "nothing has happened here yet".

  The rule the fix follows is that **the waiting goes where the answer will go**. A
  placeholder in the right place is doing two jobs a spinner elsewhere can't: it says
  what is being written, and it holds the space, so the page doesn't jump when the words
  land. Motion is the enhancement on top and never the only signal — the kit turns it
  off under `prefers-reduced-motion` and every state here still reads without it.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{App, Library, Owner}
  alias Polyphony.Authoring.CharacterSheet
  alias Polyphony.Commands.{EnterCharacter, OpenScene}

  setup :register_and_log_in_user

  setup do
    previous = Application.get_env(:polyphony, :llm)
    Application.put_env(:polyphony, :llm, provider: Polyphony.LLM.Mock)
    on_exit(fn -> Application.put_env(:polyphony, :llm, previous) end)
    :ok
  end

  defp character(user, attrs \\ %{}) do
    sheet = struct(%CharacterSheet{name: "Wren", status: :full}, attrs)
    Library.put(%{owner: Owner.of(user), kind: "character", payload: sheet})
  end

  # How many placeholder lines are on the page.
  defp skels(html), do: length(Regex.scan(~r/class="skel[ "]/, html))

  describe "a character sheet being written" do
    test "the fields show it, not just the button", %{conn: conn, user: user} do
      entry = character(user, %{premise: "", backstory: ""})

      {:ok, view, html} = live(conn, ~p"/authoring/character/#{entry.id}")
      assert skels(html) == 0

      html =
        view
        |> form("#sheet-generate-all", %{brief: "a harbour-master with a debt"})
        |> render_submit()

      # Five prose fields plus the facts section, each drawing its own placeholder in
      # the place its text will appear. The button label alone was the whole signal
      # before, on the longest wait in the product.
      assert skels(html) > 5
      assert html =~ "✦ Writing…"
    end

    test "the placeholder stands in for the empty field rather than sitting beside it",
         %{conn: conn, user: user} do
      entry = character(user)

      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

      html =
        view
        |> element(~s(button[phx-click="generate_field"][phx-value-field="premise"]))
        |> render_click()

      # An empty textarea *is* what "nothing happened" looks like, so while the field is
      # blank and being written there isn't one.
      refute html =~ ~s(id="ta-premise-0")
      assert html =~ "Writing Premise"
    end

    test "text already on the page is never replaced by grey bars",
         %{conn: conn, user: user} do
      entry = character(user, %{premise: "A harbour-master who owes the wrong people."})

      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

      html =
        view
        |> element(~s(button[phx-click="generate_field"][phx-value-field="premise"]))
        |> render_click()

      # A rewrite hasn't happened yet, so what's on the page is still the true value.
      # Swapping it for a placeholder would read as having lost it.
      assert html =~ "A harbour-master who owes the wrong people."
      assert html =~ ~s(id="ta-premise-0")
      # The new one is shown arriving underneath instead.
      assert skels(html) > 0
    end

    test "a suggestion batch is drawn as rows, and the empty line steps aside",
         %{conn: conn, user: user} do
      entry = character(user)

      {:ok, view, html} = live(conn, ~p"/authoring/character/#{entry.id}")
      assert html =~ "Nobody yet."

      html = view |> element("button[phx-click=suggest_relationships]") |> render_click()

      # Two contradictory things on screen at once — "nobody yet" and a batch of people
      # arriving — is worse than either.
      refute html =~ "Nobody yet."
      assert html =~ "Suggesting who they know"
    end

    test "the placeholder goes away when the writing lands", %{conn: conn, user: user} do
      entry = character(user)

      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

      view
      |> element(~s(button[phx-click="generate_field"][phx-value-field="premise"]))
      |> render_click()

      html = generate(view)

      assert skels(html) == 0
      assert html =~ ~s(id="ta-premise-0")
    end
  end

  describe "a turn being written" do
    setup %{user: user} do
      wren = character(user, %{name: "Wren"})

      scene = "wait-" <> Integer.to_string(System.unique_integer([:positive]))
      :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})

      :ok =
        App.dispatch(%EnterCharacter{
          scene_id: scene,
          character_id: to_string(wren.id),
          beat: 1
        })

      %{scene: scene, wren: wren}
    end

    test "it is drawn in the transcript, where the words will appear",
         %{conn: conn, scene: scene, wren: wren} do
      {:ok, view, html} = live(conn, ~p"/play/#{scene}")
      assert skels(html) == 0

      broadcast(scene, :generating, to_string(wren.id))

      html = render(view)
      assert html =~ "m-writing"
      assert skels(html) > 0
      # And it says whose turn it is, which is the thing a spinner in a bar can't.
      assert html =~ "Wren is writing their turn…"
    end

    test "it is inside the transcript, not only in the bar under it", %{conn: conn} do
      # A scene nobody has moved in yet — the case the old screen handled worst: the
      # transcript was blank, and the only sign of life was a sentence in the bottom
      # bar, below the fold on a phone.
      scene = "wait-empty-" <> Integer.to_string(System.unique_integer([:positive]))
      :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})

      {:ok, view, _html} = live(conn, ~p"/play/#{scene}")
      broadcast(scene, :director)

      [transcript] =
        render(view)
        |> then(&Regex.run(~r|<div id="transcript".*?(?=<div class="strip)|s, &1))

      assert skels(transcript) > 0
    end

    test "the Director's beat is drawn as the move it will become",
         %{conn: conn, scene: scene} do
      {:ok, view, _html} = live(conn, ~p"/play/#{scene}")

      broadcast(scene, :director)

      html = render(view)
      # `m-world`, not the voice-coloured rule — one generic placeholder for both would
      # make the transcript reflow the moment the real move arrived.
      assert html =~ "m-world"
      refute html =~ "m-writing"
      assert skels(html) > 0
    end

    test "a settled loop draws nothing", %{conn: conn, scene: scene, wren: wren} do
      {:ok, view, _html} = live(conn, ~p"/play/#{scene}")

      broadcast(scene, :generating, to_string(wren.id))
      assert render(view) =~ "m-writing"

      broadcast(scene, :idle)
      html = render(view)

      refute html =~ "m-writing"
      assert skels(html) == 0
    end
  end

  # The beat loop's own progress announcement, which every viewer of the scene receives.
  defp broadcast(scene, phase, subject \\ nil) do
    Polyphony.Broadcast.announce_progress(scene, phase, subject: subject)
    :timer.sleep(20)
  end
end
