defmodule Polyphony.Scene.CastTest do
  @moduledoc "The scene id↔name resolver at the LLM boundary (§5.2)."
  use ExUnit.Case, async: false

  alias Polyphony.{App, Library, Repo}
  alias Polyphony.Scene.Cast
  alias Polyphony.Authoring.CharacterSheet
  alias Polyphony.Commands.{OpenScene, EnterCharacter}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  test "maps a scene's id-keyed cast to display names and back" do
    mira =
      Library.put(%{
        owner_id: "1",
        kind: "character",
        payload: %CharacterSheet{name: "Mira", status: :full}
      })

    campaign =
      Library.put(%{owner_id: "1", kind: "campaign", payload: %{character_ids: [mira.id]}})

    scene = "cast-" <> Integer.to_string(System.unique_integer([:positive]))
    id = to_string(mira.id)
    :ok = App.dispatch(%OpenScene{scene_id: scene, campaign_id: campaign.id, opened_beat: 0})
    :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: id, beat: 1})

    cast = Cast.for_scene(scene)
    assert Cast.render_name(cast, id) == "Mira"
    assert Cast.resolve_id(cast, "Mira") == id
  end

  test "renders and resolves survive a rename (id is stable, name follows)" do
    mira =
      Library.put(%{
        owner_id: "1",
        kind: "character",
        payload: %CharacterSheet{name: "Mira", status: :full}
      })

    campaign =
      Library.put(%{owner_id: "1", kind: "campaign", payload: %{character_ids: [mira.id]}})

    scene = "cast-" <> Integer.to_string(System.unique_integer([:positive]))
    id = to_string(mira.id)
    :ok = App.dispatch(%OpenScene{scene_id: scene, campaign_id: campaign.id, opened_beat: 0})
    :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: id, beat: 1})

    Library.update_payload(mira.id, %CharacterSheet{name: "Miranda", status: :full})

    cast = Cast.for_scene(scene)
    # Same stable id; the display name now follows the sheet.
    assert Cast.render_name(cast, id) == "Miranda"
    assert Cast.resolve_id(cast, "Miranda") == id
  end

  test "identity fallback: unknown id renders as itself, unknown name resolves to itself" do
    scene = "cast-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})

    cast = Cast.for_scene(scene)
    assert Cast.render_name(cast, "whoever") == "whoever"
    assert Cast.resolve_id(cast, "Nobody") == "Nobody"
  end
end
