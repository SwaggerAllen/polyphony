defmodule PolyphonyWeb.PlayNarrateLiveTest do
  @moduledoc """
  ✦ Expand for narration — the one move that is entirely the author's.

  The composer has had Expand since it existed. Narrate is the other thing you can write
  from that bar, and it had nothing: the Director's own move was the only one on the
  screen with no help, on a screen whose whole argument is that generation is help.

  The interesting part isn't the button, it's what the draft is allowed to see. A world
  event goes straight into **every member's transcript**, which makes it character-facing
  in the strictest sense the app has — stricter than a scene premise, which already takes
  the public read of the world for the same reason. So the world comes in through
  `WorldBible.public/1`, and the scene-so-far carries only moves everyone present has
  already seen. Seeded with somebody's interior thought or a whisper, a drafting aid
  narrates it out loud, and the author's own transcript is where they'd find out.
  `Visibility` is not in this path; what the screen chooses to pass is.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{App, Library}
  alias Polyphony.Owner
  alias Polyphony.Authoring.{CharacterSheet, WorldBible}
  alias Polyphony.Authoring.WorldBible.Entry
  alias PolyphonyCore.Commands.{CommitPacket, EnterCharacter, OpenScene, RecordWorldEvent}
  alias PolyphonyCore.TurnPacket
  alias PolyphonyCore.Events.WorldEventOccurred

  setup :register_and_log_in_user

  setup do
    previous = Application.get_env(:polyphony, :llm)
    Application.put_env(:polyphony, :llm, provider: Polyphony.LLM.Mock)
    on_exit(fn -> Application.put_env(:polyphony, :llm, previous) end)
    :ok
  end

  defp character(user, name) do
    Library.put(%{
      owner: Owner.of(user),
      kind: "character",
      payload: %CharacterSheet{name: name, status: :full}
    })
  end

  defp scene_with_world(user, world_attrs \\ %{}) do
    wren = character(user, "Wren")

    bible =
      Library.put(%{
        owner: Owner.of(user),
        kind: "world_bible",
        payload: struct(%WorldBible{name: "Saltmarch"}, world_attrs)
      })

    camp =
      Library.put(%{
        owner: Owner.of(user),
        kind: "campaign",
        payload: %{
          kind: :campaign,
          name: "Camp",
          character_ids: [wren.id],
          bible_id: bible.id,
          scenes: []
        }
      })

    id = "narr-" <> Integer.to_string(System.unique_integer([:positive]))

    :ok =
      App.dispatch(%OpenScene{
        scene_id: id,
        opened_beat: 0,
        campaign_id: camp.id,
        location_id: "The quay, after the second bell"
      })

    :ok = App.dispatch(%EnterCharacter{scene_id: id, character_id: to_string(wren.id), beat: 1})

    %{scene: id, wren: wren}
  end

  defp capture_prompt do
    test = self()

    Application.put_env(:polyphony, :llm,
      provider: Polyphony.LLM.Stub,
      stub_response: fn messages ->
        send(test, {:prompt, Enum.map_join(messages, "\n", & &1.content)})
        {:ok, "The tide turns, and the bell rings twice."}
      end
    )
  end

  defp narrating(conn, scene) do
    {:ok, view, _html} = live(conn, ~p"/play/#{scene}")
    view |> element("button[phx-click=narrate_open]") |> render_click()
    view
  end

  test "the button is there at all", %{conn: conn, user: user} do
    %{scene: scene} = scene_with_world(user)
    view = narrating(conn, scene)

    assert render(view) =~ ~s(phx-click="expand_narrate")
  end

  test "it drafts into the box, and the draft is what gets narrated",
       %{conn: conn, user: user} do
    %{scene: scene} = scene_with_world(user)
    capture_prompt()

    view = narrating(conn, scene)
    view |> element("button[phx-click=expand_narrate]") |> render_click()
    html = generate(view)

    # Into the box to be edited, not straight onto the transcript — the same contract
    # the composer's Expand has: it drafts, you send.
    assert html =~ "The tide turns, and the bell rings twice."
    assert world_events(scene) == []

    view
    |> form("#narrate-form", %{text: "The tide turns, and the bell rings twice."})
    |> render_submit()

    assert world_events(scene) == ["The tide turns, and the bell rings twice."]
  end

  test "it sharpens what is already typed rather than replacing the idea",
       %{conn: conn, user: user} do
    %{scene: scene} = scene_with_world(user)
    capture_prompt()

    view = narrating(conn, scene)
    view |> form("#narrate-form", %{text: "somebody arrives"}) |> render_change()
    view |> element("button[phx-click=expand_narrate]") |> render_click()
    generate(view)

    assert_received {:prompt, prompt}
    assert prompt =~ "The narration so far:\nsomebody arrives"
    assert prompt =~ "Sharpen it"
  end

  test "it is grounded in where this is and who is here", %{conn: conn, user: user} do
    %{scene: scene} = scene_with_world(user, %{setting: "A tidal port."})
    capture_prompt()

    view = narrating(conn, scene)
    view |> element("button[phx-click=expand_narrate]") |> render_click()
    generate(view)

    assert_received {:prompt, prompt}
    assert prompt =~ "A tidal port."
    assert prompt =~ "The quay, after the second bell"
    assert prompt =~ "Wren"
  end

  test "a concealed world rule does not reach the draft", %{conn: conn, user: user} do
    %{scene: scene} =
      scene_with_world(user, %{
        rules: [
          %Entry{statement: "The tide runs twice a day.", concealed: false},
          %Entry{statement: "The core is a sleeping thing.", concealed: true}
        ]
      })

    capture_prompt()

    view = narrating(conn, scene)
    view |> element("button[phx-click=expand_narrate]") |> render_click()
    generate(view)

    assert_received {:prompt, prompt}

    # What comes back goes into every member's transcript, so this is the strictest
    # character-facing read in the app — stricter than a scene premise, which takes the
    # same one for the same reason.
    assert prompt =~ "The tide runs twice a day."
    refute prompt =~ "The core is a sleeping thing."
  end

  test "a whisper is not part of the scene so far", %{conn: conn, user: user} do
    %{scene: scene, wren: wren} = scene_with_world(user)

    :ok =
      App.dispatch(%RecordWorldEvent{
        scene_id: scene,
        beat: 1,
        content: "Rain starts on the tin roof."
      })

    say(scene, wren, "Bring the ledger over.", nil)
    say(scene, wren, "I burned the second page.", ["someone"])

    capture_prompt()

    view = narrating(conn, scene)
    view |> element("button[phx-click=expand_narrate]") |> render_click()
    generate(view)

    assert_received {:prompt, prompt}

    assert prompt =~ "Rain starts on the tin roof."
    assert prompt =~ "Bring the ledger over."
    # A whisper reached two people. Feeding it to a drafting aid whose output goes into
    # the shared transcript is how a secret gets narrated out loud.
    refute prompt =~ "I burned the second page."
  end

  test "a failed draft says so and leaves the box alone", %{conn: conn, user: user} do
    %{scene: scene} = scene_with_world(user)

    Application.put_env(:polyphony, :llm,
      provider: Polyphony.LLM.Stub,
      stub_response: {:error, :nope}
    )

    view = narrating(conn, scene)
    view |> form("#narrate-form", %{text: "somebody arrives"}) |> render_change()
    view |> element("button[phx-click=expand_narrate]") |> render_click()
    html = generate(view)

    assert html =~ "Couldn&#39;t draft that"
    # Still yours to send by hand.
    assert html =~ "somebody arrives"
  end

  defp say(scene, character, content, addressed_to) do
    move = %TurnPacket.Move{
      seq: 1,
      type: :speech,
      content: content,
      addressed_to: addressed_to || [],
      audibility: if(addressed_to, do: :private, else: :normal)
    }

    :ok =
      App.dispatch(%CommitPacket{
        scene_id: scene,
        packet_id: "#{scene}-1-#{character.id}-#{System.unique_integer([:positive])}",
        character_id: to_string(character.id),
        beat: 1,
        packet: %TurnPacket{moves: [move]}
      })
  end

  defp world_events(scene) do
    App
    |> Commanded.EventStore.stream_forward(scene)
    |> Enum.map(& &1.data)
    |> Enum.filter(&match?(%WorldEventOccurred{}, &1))
    |> Enum.map(& &1.content)
  end
end
