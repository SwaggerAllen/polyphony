defmodule Polyphony.Jobs.RunBeatCampaignModelTest do
  @moduledoc """
  Per-campaign model selection (§9): a campaign can point its Director/cast at a
  better-provisioned model, and its own heavy fallback overrides the global one —
  the escape hatch when the deployment default's serverless pool is overloaded.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{App, Library, Repo}
  alias Polyphony.Commands.{OpenScene, EnterCharacter}
  alias Polyphony.Director.BeatOps
  alias PolyphonyCore.Events.TurnOrderDeclared
  alias Polyphony.Jobs.RunBeat

  # Succeeds only on the campaign's chosen heavy model; the workhorse returns empty so
  # the fallback must fire, and it must target the campaign's id — not the global one.
  defmodule CampaignHeavyDirector do
    @behaviour Polyphony.LLM.Provider

    @decision Jason.encode!(%{
                "control" => "yield_to_user",
                "cast" => [%{"character_id" => "mira"}],
                "world_events" => [],
                "proposal_rulings" => []
              })

    @impl true
    def complete(_messages, opts) do
      if Keyword.get(opts, :model) == "campaign/Heavy-405B",
        do: {:ok, @decision},
        else: {:error, :empty_response}
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    previous = Application.get_env(:polyphony, :llm)

    # Global heavy is a DIFFERENT id — the campaign setting must win.
    Application.put_env(:polyphony, :llm,
      provider: CampaignHeavyDirector,
      models: %{workhorse: "global/Work", heavy: "global/Heavy"}
    )

    on_exit(fn -> Application.put_env(:polyphony, :llm, previous) end)
    :ok
  end

  test "the Director's heavy retry uses the campaign's heavy_model, not the global one" do
    campaign =
      Library.put(%{
        owner_id: "1",
        kind: "campaign",
        payload: %{llm: %{heavy_model: "campaign/Heavy-405B"}}
      })

    scene = "rbcm-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: scene, campaign_id: campaign.id, opened_beat: 0})
    :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: "mira", beat: 1})

    Oban.Testing.with_testing_mode(:inline, fn ->
      RunBeat.enqueue(%{"scene_id" => scene, "beat" => 2, "control_hint" => "yield_to_user"})
    end)

    # The decision only succeeds if the retry hit the campaign's heavy id.
    assert Enum.any?(
             BeatOps.stored_events(scene),
             &match?(%TurnOrderDeclared{beat: 2}, &1)
           )
  end
end
