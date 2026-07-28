defmodule Polyphony.Jobs.RunBeatFallbackTest do
  @moduledoc """
  When the workhorse model returns an empty body (a known Qwen quirk, §12) the
  Director retries once on the heavy model rather than stalling Continue.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{App, Repo}
  alias Polyphony.Commands.{OpenScene, EnterCharacter}
  alias Polyphony.Director.BeatOps
  alias Polyphony.Events.TurnOrderDeclared
  alias Polyphony.Jobs.RunBeat

  # Succeeds only on the heavy model; the workhorse call returns an empty body.
  defmodule HeavyOnlyDirector do
    @behaviour Polyphony.LLM.Provider

    @decision Jason.encode!(%{
                "control" => "yield_to_user",
                "cast" => [%{"character_id" => "mira"}],
                "world_events" => [],
                "proposal_rulings" => []
              })

    @impl true
    def complete(_messages, opts) do
      if Keyword.get(opts, :model) == "HEAVY",
        do: {:ok, @decision},
        else: {:error, :empty_response}
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    previous = Application.get_env(:polyphony, :llm)

    Application.put_env(:polyphony, :llm,
      provider: HeavyOnlyDirector,
      models: %{workhorse: "WORK", heavy: "HEAVY"}
    )

    on_exit(fn -> Application.put_env(:polyphony, :llm, previous) end)
    :ok
  end

  test "the Director retries on the heavy model when the workhorse returns empty" do
    scene = "rbf-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})
    :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: "mira", beat: 1})

    Oban.Testing.with_testing_mode(:inline, fn ->
      RunBeat.enqueue(%{"scene_id" => scene, "beat" => 2, "control_hint" => "yield_to_user"})
    end)

    # The decision succeeded via the heavy retry, so the beat's turn order was declared
    # (a workhorse-only failure would have yielded with nothing on the log).
    assert Enum.any?(
             BeatOps.stored_events(scene),
             &match?(%TurnOrderDeclared{beat: 2}, &1)
           )
  end
end
