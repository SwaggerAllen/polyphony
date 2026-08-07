defmodule Polyphony.Jobs.RunBeatContextTest do
  @moduledoc """
  The Director must receive the scene roster in its judgment context. `cast_hint`
  is read only by the offline Mock; the real provider casts from the prompt, so
  without a roster in the messages the beat silently yields (the "Continue casts
  nothing" bug). This pins the roster + cast instruction into the Director call.
  """
  use ExUnit.Case, async: false

  alias Polyphony.App
  alias PolyphonyCore.Commands.{OpenScene, EnterCharacter}
  alias Polyphony.Jobs.RunBeat

  defp setup_scene(members) do
    scene = "rbc-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})

    for m <- members do
      :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: m, beat: 1})
    end

    scene
  end

  # A capturing decision: forward the Director's messages to the test, then yield
  # an empty cast so the beat rests (no cast generation to muddy the capture).
  defp empty_cast_json do
    Jason.encode!(%{
      "control" => "yield_to_user",
      "cast" => [],
      "world_events" => [],
      "proposal_rulings" => []
    })
  end

  setup do
    previous = Application.get_env(:polyphony, :llm)
    test = self()

    Application.put_env(:polyphony, :llm,
      provider: Polyphony.LLM.Stub,
      stub_response: fn messages ->
        send(test, {:director_messages, messages})
        {:ok, empty_cast_json()}
      end
    )

    on_exit(fn -> Application.put_env(:polyphony, :llm, previous) end)
    :ok
  end

  test "the Director's judgment context names the present roster and the cast instruction" do
    scene = setup_scene(["mira", "otto"])

    Oban.Testing.with_testing_mode(:inline, fn ->
      RunBeat.enqueue(%{
        "scene_id" => scene,
        "beat" => 2,
        "provider" => "Elixir.Polyphony.LLM.Stub",
        "control_hint" => "yield_to_user"
      })
    end)

    assert_received {:director_messages, messages}

    text = messages |> Enum.map_join("\n", & &1.content)

    assert text =~ "mira"
    assert text =~ "otto"
    assert text =~ "Cast the characters who should act"
    assert text =~ "Use these exact ids"
  end

  test "with no one present the roster reads empty rather than being omitted" do
    scene = setup_scene([])

    Oban.Testing.with_testing_mode(:inline, fn ->
      RunBeat.enqueue(%{
        "scene_id" => scene,
        "beat" => 2,
        "provider" => "Elixir.Polyphony.LLM.Stub"
      })
    end)

    assert_received {:director_messages, messages}
    text = messages |> Enum.map_join("\n", & &1.content)

    assert text =~ "no characters are present"
  end
end
