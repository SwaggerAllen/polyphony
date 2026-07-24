defmodule Polyphony.Failures.WiringTest do
  @moduledoc """
  A refusal that survives the model swap records a user-facing, editable failure
  carrying the messages needed to edit-and-resubmit (§12).
  """
  use ExUnit.Case, async: false

  alias Polyphony.{App, Repo, Context, Failures}
  alias Polyphony.Context.Store
  alias Polyphony.Authoring.CharacterSheet
  alias Polyphony.ReadModels.Failure
  alias Polyphony.Commands.{OpenScene, EnterCharacter}
  alias Polyphony.Jobs.RunBeat

  # Casts everyone for the beat, but refuses every character generation.
  defmodule RefusingProvider do
    @behaviour Polyphony.LLM.Provider

    def complete(_messages, opts) do
      case Keyword.get(opts, :response) do
        :decision ->
          cast = opts |> Keyword.get(:cast_hint, []) |> Enum.map(&%{character_id: to_string(&1)})

          {:ok,
           Jason.encode!(%{
             control: "yield_to_user",
             cast: cast,
             world_events: [],
             proposal_rulings: []
           })}

        _ ->
          {:ok, "I'm sorry, but I can't help with that request."}
      end
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "a persistent refusal records an editable failure with the messages to resubmit" do
    scene = "fw-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})
    :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: "mira", beat: 1})
    sheet = %CharacterSheet{name: "mira", premise: "mira waits.", voice: "plain"}

    Store.put(
      scene,
      "mira",
      Context.materialize(scene_id: scene, character_id: "mira", sheet: sheet, premise: "A hall.")
    )

    Oban.Testing.with_testing_mode(:inline, fn ->
      RunBeat.enqueue(%{
        "scene_id" => scene,
        "beat" => 2,
        "provider" => to_string(RefusingProvider),
        "control_hint" => "yield_to_user"
      })
    end)

    assert [%Failure{} = f] = Failures.list_open(scene, repo: Repo)
    assert f.operation == "packet"
    assert f.kind == "refusal"
    assert f.editable == true
    assert f.subject == "mira"
    # The stored args carry the messages, so the user can edit and resubmit.
    assert is_list(f.args["messages"])
    assert f.args["character_id"] == "mira"
  end
end
