defmodule Polyphony.Context.RebuildTest do
  @moduledoc """
  A cold context cache (ETS wiped by a restart) must rebuild from durable data — the
  campaign's sheet + the scene's premise — so an autonomous turn conditions on the real
  character with the TurnPacket schema, not a bare "take your turn" that the model
  answers with foreign JSON (the `schema_invalid` failure seen in prod after a boot).
  """
  use ExUnit.Case, async: false

  alias Polyphony.{App, Library, Repo}
  alias Polyphony.Context.{Rebuild, Store}
  alias Polyphony.Authoring.CharacterSheet
  alias Polyphony.Commands.{OpenScene, EnterCharacter}
  alias Polyphony.Director.BeatOps

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  defp campaign_with_cast do
    char =
      Library.put(%{
        owner_id: "1",
        kind: "character",
        payload: %CharacterSheet{name: "Lydia", status: :full, premise: "a nervous thief"}
      })

    Library.put(%{
      owner_id: "1",
      kind: "campaign",
      payload: %{character_ids: [char.id], premise: "a heist", name: "The Long Con"}
    })
  end

  defp open_scene(campaign_id) do
    scene = "reb-" <> Integer.to_string(System.unique_integer([:positive]))

    :ok =
      App.dispatch(%OpenScene{
        scene_id: scene,
        campaign_id: campaign_id,
        premise: "a heist",
        opened_beat: 0
      })

    :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: "Lydia", beat: 1})
    scene
  end

  test "rebuilds a cast member's context from the campaign sheet, matched by name" do
    campaign = campaign_with_cast()
    scene = open_scene(campaign.id)

    assert {:ok, ctx} = Rebuild.for_character(scene, "Lydia")
    assert ctx.character_id == "Lydia"
    # The persona made it in — this is the real sheet, not a stub.
    assert ctx.prefix =~ "Lydia"
  end

  test "returns :error when the scene has no resolvable campaign sheet" do
    scene = "reb-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})

    assert :error = Rebuild.for_character(scene, "Ghost")
  end

  test "messages_for on a cold cache rebuilds and carries the persona + TurnPacket schema" do
    campaign = campaign_with_cast()
    scene = open_scene(campaign.id)

    # Nothing seeded into the Store — simulate the post-restart cold cache.
    assert :error = Store.fetch(scene, "Lydia")

    messages = BeatOps.messages_for(scene, 2, "Lydia")
    text = Enum.map_join(messages, "\n", & &1.content)

    # The real persona (rebuilt), plus the explicit JSON schema (so no foreign shapes).
    assert text =~ "Lydia"
    assert text =~ ~s("moves")
    # And it re-cached, so the next turn is a cache hit.
    assert {:ok, _ctx} = Store.fetch(scene, "Lydia")
  end

  test "messages_for still states the schema even when no sheet can be resolved" do
    scene = "reb-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})
    :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: "Ghost", beat: 1})

    messages = BeatOps.messages_for(scene, 2, "Ghost")
    text = Enum.map_join(messages, "\n", & &1.content)

    # Bare fallback — but it still spells out the schema so the model can't free-form.
    assert text =~ "You are Ghost"
    assert text =~ ~s("moves")
  end
end
