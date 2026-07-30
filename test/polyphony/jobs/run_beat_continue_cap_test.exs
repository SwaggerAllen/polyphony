defmodule Polyphony.Jobs.RunBeatContinueCapTest do
  @moduledoc """
  A user-initiated Continue (`control_hint: "yield_to_user"`) advances exactly one beat
  even when the Director's decision says `control: continue` — the yield hint is
  authoritative, so the loop doesn't self-chain. Without the hint (a future Auto/Play
  control), the Director paces the exchange up to the depth cap.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{App, Context}
  alias Polyphony.Context.Store
  alias Polyphony.Authoring.CharacterSheet
  alias Polyphony.Commands.{OpenScene, EnterCharacter}
  alias Polyphony.Events.TurnOrderDeclared
  alias Polyphony.Jobs.RunBeat

  # Always wants to keep going: the Director decision returns control: continue; character
  # turns return a canned valid TurnPacket. One provider, dispatched by the response tag.
  defmodule AlwaysContinueDirector do
    @behaviour Polyphony.LLM.Provider

    @decision Jason.encode!(%{
                "control" => "continue",
                "cast" => [%{"character_id" => "mira"}],
                "world_events" => [],
                "proposal_rulings" => []
              })

    @impl true
    def complete(_messages, opts) do
      case Keyword.get(opts, :response) do
        :decision -> {:ok, @decision}
        _ -> {:ok, Polyphony.LLM.Stub.canned_packet_json()}
      end
    end
  end

  @provider "Elixir.Polyphony.Jobs.RunBeatContinueCapTest.AlwaysContinueDirector"

  defp scene do
    s = "cap-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: s, opened_beat: 0})
    :ok = App.dispatch(%EnterCharacter{scene_id: s, character_id: "mira", beat: 1})
    sheet = %CharacterSheet{name: "mira", premise: "present", voice: "plain"}

    Store.put(
      s,
      "mira",
      Context.materialize(scene_id: s, character_id: "mira", sheet: sheet, premise: "A hall.")
    )

    s
  end

  defp beats_run(scene) do
    scene
    |> then(&Commanded.EventStore.stream_forward(App, &1))
    |> Enum.count(&match?(%TurnOrderDeclared{}, &1.data))
  end

  test "an explicit yield hint caps Continue to a single beat despite control: continue" do
    s = scene()

    Oban.Testing.with_testing_mode(:inline, fn ->
      RunBeat.enqueue(%{
        "scene_id" => s,
        "beat" => 2,
        "provider" => @provider,
        "control_hint" => "yield_to_user"
      })
    end)

    assert beats_run(s) == 1
  end

  test "without the yield hint the Director self-chains up to the depth cap (Auto-style)" do
    s = scene()

    Oban.Testing.with_testing_mode(:inline, fn ->
      RunBeat.enqueue(%{
        "scene_id" => s,
        "beat" => 2,
        "provider" => @provider,
        "control_hint" => "continue"
      })
    end)

    # Default depth cap is 3 beats.
    assert beats_run(s) == 3
  end
end
