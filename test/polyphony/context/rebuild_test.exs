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
  alias Polyphony.Authoring.{ArcEntry, WorldArcEntry}
  alias Polyphony.ReadModels.ArcEntry, as: ArcRM
  alias PolyphonyCore.Commands.{OpenScene, EnterCharacter}
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

  test "rebuild carries the scene's authored location into the character context (§2.3)" do
    campaign = campaign_with_cast()
    scene = "reb-" <> Integer.to_string(System.unique_integer([:positive]))

    :ok =
      App.dispatch(%OpenScene{
        scene_id: scene,
        campaign_id: campaign.id,
        premise: "a heist",
        location_id: "the vault antechamber",
        opened_beat: 0
      })

    :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: "Lydia", beat: 1})

    # Cold cache → rebuild from SceneOpened; the authored location reaches generation.
    assert :error = Store.fetch(scene, "Lydia")
    messages = BeatOps.messages_for(scene, 2, "Lydia")
    text = Enum.map_join(messages, "\n", & &1.content)

    assert text =~ "Location: the vault antechamber"
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

  # ── World + character arc reach generation (§2.8) ────────────────────────────

  defp open_scene_at(campaign_id, location) do
    scene = "reb-" <> Integer.to_string(System.unique_integer([:positive]))

    :ok =
      App.dispatch(%OpenScene{
        scene_id: scene,
        campaign_id: campaign_id,
        premise: "a heist",
        location_id: location,
        opened_beat: 0
      })

    :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: "Lydia", beat: 1})
    scene
  end

  defp msg_text(scene),
    do: scene |> BeatOps.messages_for(2, "Lydia") |> Enum.map_join("\n", & &1.content)

  test "canon global world arc reaches the rebuilt character context (§2.8)" do
    campaign = campaign_with_cast()

    ArcRM.put_world(
      Repo,
      %WorldArcEntry{
        kind: :discovery,
        scope: :global,
        statement: "The moon fell from the sky.",
        status: :canon
      },
      campaign.id
    )

    scene = open_scene(campaign.id)
    assert :error = Store.fetch(scene, "Lydia")
    assert msg_text(scene) =~ "The moon fell from the sky."
  end

  test "a canon local world fact reaches only scenes at its location (§2.8)" do
    campaign = campaign_with_cast()

    ArcRM.put_world(
      Repo,
      %WorldArcEntry{
        kind: :discovery,
        scope: :local,
        location_id: "the vault",
        statement: "The vault alarm is broken.",
        status: :canon
      },
      campaign.id
    )

    assert open_scene_at(campaign.id, "the vault") |> msg_text() =~ "The vault alarm is broken."
    refute open_scene_at(campaign.id, "the rooftop") |> msg_text() =~ "The vault alarm is broken."
  end

  test "resolves the sheet by stable library id, surviving a rename (§5.2 phase 1)" do
    char =
      Library.put(%{
        owner_id: "1",
        kind: "character",
        payload: %CharacterSheet{name: "Original", status: :full, premise: "a thief"}
      })

    campaign =
      Library.put(%{
        owner_id: "1",
        kind: "campaign",
        payload: %{character_ids: [char.id], premise: "a heist", name: "C"}
      })

    scene = "reb-" <> Integer.to_string(System.unique_integer([:positive]))
    # The scene keys the character by its stable library id, not its name.
    cid = to_string(char.id)

    :ok =
      App.dispatch(%OpenScene{
        scene_id: scene,
        campaign_id: campaign.id,
        premise: "a heist",
        opened_beat: 0
      })

    :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: cid, beat: 1})

    assert {:ok, ctx} = Rebuild.for_character(scene, cid)
    assert ctx.prefix =~ "Original"

    # Rename the character — its stable id (the scene's character_id) is unchanged, so
    # the rebuild still finds the sheet and reflects the new name.
    Library.update_payload(char.id, %CharacterSheet{
      name: "Renamed",
      status: :full,
      premise: "a thief"
    })

    assert {:ok, ctx2} = Rebuild.for_character(scene, cid)
    assert ctx2.prefix =~ "Renamed"
    refute ctx2.prefix =~ "Original"
  end

  test "canon character arc now reaches the rebuilt context, not just publishing (§2.8 caveat)" do
    campaign = campaign_with_cast()

    ArcRM.put(
      Repo,
      %ArcEntry{
        kind: :revision,
        sheet_field: "premise",
        statement: "a master thief who now works alone",
        status: :canon
      },
      "Lydia"
    )

    scene = open_scene(campaign.id)
    text = msg_text(scene)
    assert text =~ "a master thief who now works alone"
    refute text =~ "a nervous thief"
  end
end
