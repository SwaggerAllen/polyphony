defmodule Polyphony.Costs.AttributionTest do
  @moduledoc "Resolving a scene's autonomous spend to the campaign owner (§B5)."
  use ExUnit.Case, async: false

  alias Polyphony.{App, Library, Repo}
  alias Polyphony.Costs.Attribution
  alias Polyphony.Commands.OpenScene

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp scene, do: "attr-" <> Integer.to_string(System.unique_integer([:positive]))

  test "resolves the campaign owner (as an integer user id) from the scene" do
    campaign = Library.put(%{owner_id: "7", kind: "campaign", payload: %{}})
    s = scene()
    :ok = App.dispatch(%OpenScene{scene_id: s, campaign_id: campaign.id, opened_beat: 0})

    assert %{user_id: 7, campaign_id: cid} = Attribution.for_scene(s)
    assert cid == campaign.id
  end

  test "a scene with no campaign yields no attribution" do
    s = scene()
    :ok = App.dispatch(%OpenScene{scene_id: s, opened_beat: 0})
    assert %{user_id: nil, campaign_id: nil} = Attribution.for_scene(s)
  end

  test "an unknown scene yields no attribution and does not crash" do
    assert %{user_id: nil, campaign_id: nil} = Attribution.for_scene("no-such-scene-xyz")
  end
end
