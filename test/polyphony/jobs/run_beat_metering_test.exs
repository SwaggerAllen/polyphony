defmodule Polyphony.Jobs.RunBeatMeteringTest do
  @moduledoc """
  Autonomous beat spend is billed to the campaign owner (§B5): the Director's
  decision and the cast turns it drives both land in the ledger under the owner,
  resolved from the scene's campaign — no logged-in user needed.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{App, Context, Costs, Library, Repo}
  alias Polyphony.Context.Store
  alias Polyphony.Costs.Ledger
  alias Polyphony.Authoring.CharacterSheet
  alias Polyphony.Commands.{OpenScene, EnterCharacter}
  alias Polyphony.Jobs.RunBeat

  @mock "Elixir.Polyphony.LLM.Mock"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  test "the Director decision and cast turns bill the campaign owner" do
    campaign = Library.put(%{owner_id: "13", kind: "campaign", payload: %{}})
    scene = "rbm-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: scene, campaign_id: campaign.id, opened_beat: 0})

    for m <- ["mira", "otto"] do
      :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: m, beat: 1})
      sheet = %CharacterSheet{name: m, premise: "#{m} is present.", voice: "plain"}

      ctx =
        Context.materialize(scene_id: scene, character_id: m, sheet: sheet, premise: "A hall.")

      Store.put(scene, m, ctx)
    end

    Oban.Testing.with_testing_mode(:inline, fn ->
      RunBeat.enqueue(%{
        "scene_id" => scene,
        "beat" => 2,
        "provider" => @mock,
        "control_hint" => "yield_to_user"
      })
    end)

    # The owner is billed, on both the per-user and per-campaign axes.
    assert Costs.spent_today(13) > 0
    assert Costs.spent_campaign(campaign.id) > 0

    # Both the Director judgment and the cast turns are attributed.
    kinds = Repo.all(Ledger) |> Enum.map(& &1.kind) |> Enum.uniq()
    assert "director" in kinds
    assert "generation" in kinds

    # Every row is attributed to the owner — nothing leaked in unattributed.
    assert Enum.all?(Repo.all(Ledger), &(&1.user_id == 13))
  end
end
