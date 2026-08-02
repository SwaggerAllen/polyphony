defmodule Polyphony.Authoring.SceneGateTest do
  @moduledoc "The arc-review gate on opening a new scene (§3.0), keyed by character id."
  use ExUnit.Case, async: false

  alias Polyphony.Repo
  alias Polyphony.Authoring.{SceneGate, ArcEntry, WorldArcEntry}
  alias Polyphony.ReadModels.ArcEntry, as: ArcRM

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp propose_char(name),
    do: ArcRM.put(Repo, %ArcEntry{kind: :discovery, statement: "x", status: :proposed}, name)

  defp propose_world(campaign_id),
    do:
      ArcRM.put_world(
        Repo,
        %WorldArcEntry{kind: :discovery, scope: :global, statement: "x", status: :proposed},
        campaign_id
      )

  test "a clean cast and clean world opens" do
    assert :ok = SceneGate.check("camp-1", ["Mira", "Otto"], Repo)
  end

  test "a cast member with pending arc blocks — per cast, not per backlog" do
    propose_char("Mira")

    # Mira in the cast blocks...
    assert {:blocked, %{characters: ["Mira"], world: 0}} =
             SceneGate.check("camp-1", ["Mira", "Otto"], Repo)

    # ...but a scene that doesn't cast Mira is unaffected.
    assert :ok = SceneGate.check("camp-1", ["Otto"], Repo)
  end

  test "pending world arc blocks the whole campaign regardless of cast" do
    propose_world("camp-1")
    assert {:blocked, %{characters: [], world: 1}} = SceneGate.check("camp-1", ["Otto"], Repo)
  end

  test "accepting clears the block" do
    row = propose_char("Mira")
    assert {:blocked, _} = SceneGate.check("camp-1", ["Mira"], Repo)

    ArcRM.accept(Repo, row.id)
    assert :ok = SceneGate.check("camp-1", ["Mira"], Repo)
  end

  test "a rejected proposal no longer blocks either" do
    row = propose_char("Mira")
    ArcRM.reject(Repo, row.id)
    assert :ok = SceneGate.check("camp-1", ["Mira"], Repo)
  end
end
