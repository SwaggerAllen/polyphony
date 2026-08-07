defmodule PolyphonyWeb.PlayMentionsLiveTest do
  @moduledoc "Mention-stubbing (§B8): scan a scene's prose for uncreated characters and stub them."
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{App, Library}
  alias Polyphony.Owner
  alias Polyphony.Authoring.CharacterSheet
  alias PolyphonyCore.TurnPacket
  alias PolyphonyCore.TurnPacket.{Move, SelfState}
  alias PolyphonyCore.Commands.{OpenScene, EnterCharacter, CommitPacket}
  alias Polyphony.Director.BeatOps

  setup :register_and_log_in_user

  setup do
    previous = Application.get_env(:polyphony, :llm)
    Application.put_env(:polyphony, :llm, provider: Polyphony.LLM.Mock)
    on_exit(fn -> Application.put_env(:polyphony, :llm, previous) end)
    :ok
  end

  defp campaign(user) do
    Library.put(%{
      owner: Owner.of(user),
      kind: "campaign",
      payload: %{kind: :campaign, name: "Camp", character_ids: [], bible_id: nil, scenes: []}
    })
  end

  test "scanning stubs characters mentioned in the scene but not yet created",
       %{conn: conn, user: user} do
    camp = campaign(user)
    scene = "ment-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: scene, campaign_id: camp.id, opened_beat: 0})
    :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: "mira", beat: 1})

    # Mira mentions someone off-stage.
    packet = %TurnPacket{
      moves: [%Move{seq: 1, type: :speech, content: "Have you seen Bram lately?"}],
      self_state: %SelfState{}
    }

    :ok =
      App.dispatch(%CommitPacket{
        scene_id: scene,
        character_id: "mira",
        beat: 1,
        packet_id: BeatOps.packet_id(scene, 1, "mira"),
        packet: packet,
        edited: true
      })

    before = Enum.count(Library.list_for_owner(Owner.of(user)), &(&1.kind == "character"))

    {:ok, view, _html} = live(conn, ~p"/play/#{scene}")
    view |> element("button[phx-click=toggle_cast]") |> render_click()
    view |> element("button[phx-click=find_mentions]") |> render_click()
    generate(view)

    chars = Library.list_for_owner(Owner.of(user)) |> Enum.filter(&(&1.kind == "character"))
    # New pending stubs were created (the Mock returns deterministic names).
    assert Enum.count(chars) > before
    assert Enum.all?(chars, &match?(%CharacterSheet{}, Library.payload(&1)))
    assert Enum.any?(chars, &(Library.payload(&1).status == :stub))

    # And they join the story that mentioned them. A stub in no campaign is one the
    # roster, the cast tab's "fill them in" prompt, and the library's own grouping by
    # campaign all fail to see.
    roster = Library.payload(Library.get(camp.id))[:character_ids]
    assert roster != []

    assert Enum.all?(roster, fn id -> Library.payload(Library.get(id)).status == :stub end)
  end
end
