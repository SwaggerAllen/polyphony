defmodule Polyphony.Director.GhostCastTest do
  @moduledoc """
  The Director casting somebody who isn't in the scene (§B7, §5.2).

  `Cast.resolve_id/2` has an identity fallback, so a name the Director invents comes
  back as *itself* and looks exactly like a character id. Left alone it reaches the
  declared turn order, where every downstream consumer — the walk, `packet_id`,
  membership — treats it as a routing key. Their `CommitPacket` can only be rejected
  `:not_a_member`, so they generate and print nothing, and because the walk re-derives
  progress from the scene stream the slot never goes terminal: the same generation is
  paid for again on every pass.

  Three guards, tested here: the pick never reaches the order (it goes to the
  introduction queue instead), the walk skips a non-member slot, and a rejected commit
  is recorded as a failure rather than a success.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{App, Context}
  alias Polyphony.Context.Store
  alias Polyphony.Authoring.CharacterSheet
  alias Polyphony.Commands.{OpenScene, EnterCharacter, DeclareTurnOrder}
  alias Polyphony.Director.{BeatOps, BeatWalk}
  alias Polyphony.Director.Commands.OpenBeat
  alias Polyphony.Jobs.{GeneratePacket, RunBeat}
  alias Polyphony.ReadModels.Failure

  alias Polyphony.Events.{
    ThoughtOccurred,
    TurnOrderDeclared,
    IntroductionProposed,
    PacketFailed,
    PacketRecorded
  }

  @stub "Elixir.Polyphony.LLM.Stub"
  @ghost "The Leviathan"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Polyphony.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Polyphony.Repo, {:shared, self()})
    on_exit(fn -> Application.put_env(:polyphony, :llm, llm_env()) end)
    :ok
  end

  defp llm_env, do: Application.get_env(:polyphony, :llm, [])

  defp stored(stream),
    do: App |> Commanded.EventStore.stream_forward(stream) |> Enum.map(& &1.data)

  defp setup_scene(members) do
    scene = "ghost-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})

    for m <- members do
      :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: m, beat: 1})
      sheet = %CharacterSheet{name: m, premise: "#{m} is present.", voice: "plain"}
      ctx = Context.materialize(scene_id: scene, character_id: m, sheet: sheet, premise: "A sub.")
      Store.put(scene, m, ctx)
    end

    scene
  end

  # A Director that casts a name nobody in the scene answers to, alongside a real
  # member; every character turn returns the canned packet.
  defp stub_director_casting(names) do
    decision =
      Jason.encode!(%{
        control: "yield_to_user",
        cast: Enum.map(names, &%{character_id: &1}),
        world_events: [],
        introductions: [],
        proposal_rulings: []
      })

    fun = fn messages ->
      if Enum.any?(messages, &String.contains?(&1.content, "proposal_rulings")),
        do: {:ok, decision},
        else: {:ok, Polyphony.LLM.Stub.canned_packet_json()}
    end

    Application.put_env(:polyphony, :llm, Keyword.put(llm_env(), :stub_response, fun))
  end

  describe "a cast pick who is not in the scene" do
    test "never reaches the declared turn order, and generates nothing" do
      scene = setup_scene(["227"])
      stub_director_casting([@ghost, "227"])

      Oban.Testing.with_testing_mode(:inline, fn ->
        RunBeat.enqueue(%{
          "scene_id" => scene,
          "beat" => 2,
          "provider" => @stub,
          "max_depth" => 1,
          "control_hint" => "yield_to_user"
        })
      end)

      events = stored(scene)

      assert %TurnOrderDeclared{order: ["227"]} =
               Enum.find(events, &match?(%TurnOrderDeclared{}, &1))

      # The member played their turn; the ghost neither printed nor was recorded.
      assert Enum.any?(events, &match?(%ThoughtOccurred{character_id: "227"}, &1))
      refute Enum.any?(events, &match?(%ThoughtOccurred{character_id: @ghost}, &1))
      refute Enum.any?(stored("#{scene}-b2"), &match?(%PacketRecorded{character_id: @ghost}, &1))
    end

    test "is queued as an introduction for the author to admit (§B7)" do
      scene = setup_scene(["227"])
      stub_director_casting([@ghost, "227"])

      Oban.Testing.with_testing_mode(:inline, fn ->
        RunBeat.enqueue(%{
          "scene_id" => scene,
          "beat" => 2,
          "provider" => @stub,
          "max_depth" => 1,
          "control_hint" => "yield_to_user"
        })
      end)

      assert Enum.any?(stored(scene), &match?(%IntroductionProposed{name: @ghost}, &1))
    end

    test "yields rather than opening a beat when nobody cast is present" do
      scene = setup_scene(["227"])
      stub_director_casting([@ghost])

      Oban.Testing.with_testing_mode(:inline, fn ->
        RunBeat.enqueue(%{
          "scene_id" => scene,
          "beat" => 2,
          "provider" => @stub,
          "max_depth" => 1,
          "control_hint" => "yield_to_user"
        })
      end)

      assert BeatOps.beat_events(scene, 2) == []
      refute Enum.any?(stored(scene), &match?(%ThoughtOccurred{beat: 2}, &1))
    end
  end

  describe "the walk" do
    test "skips a declared slot for someone who is not a member at that beat" do
      scene = setup_scene(["227"])

      :ok =
        App.dispatch(%DeclareTurnOrder{scene_id: scene, beat: 2, order: [@ghost, "227"]})

      # Without the membership guard this is `{:autonomous, "The Leviathan"}` — a slot
      # that can never go terminal, so the walk hands it the same turn forever.
      assert {:autonomous, "227"} = BeatWalk.next(scene, 2)
    end
  end

  describe "a commit the scene rejects" do
    test "is a failed slot, not a completed one" do
      scene = setup_scene(["227"])
      stub_director_casting(["227"])

      # Open the beat with the ghost in the cast, so the beat aggregate accepts the
      # outcome, and drive the one slot directly — the walk's guard is bypassed here on
      # purpose: this pins the job's own handling of the aggregate's verdict.
      :ok =
        App.dispatch(%OpenBeat{
          beat_ref: BeatOps.beat_ref(scene, 2),
          scene_id: scene,
          beat: 2,
          cast: [@ghost]
        })

      result =
        Oban.Testing.with_testing_mode(:inline, fn ->
          GeneratePacket.perform(%Oban.Job{
            args: %{
              "scene_id" => scene,
              "beat" => 2,
              "character_id" => @ghost,
              "packet_id" => BeatOps.packet_id(scene, 2, @ghost),
              "provider" => @stub
            }
          })
        end)

      assert {:cancel, {:rejected, :not_a_member}} = result
      refute Enum.any?(stored(scene), &match?(%ThoughtOccurred{character_id: @ghost}, &1))
    end

    test "records the failure on the beat so the slot goes terminal" do
      scene = setup_scene(["227"])
      stub_director_casting(["227"])

      :ok =
        App.dispatch(%OpenBeat{
          beat_ref: BeatOps.beat_ref(scene, 2),
          scene_id: scene,
          beat: 2,
          cast: [@ghost]
        })

      Oban.Testing.with_testing_mode(:inline, fn ->
        GeneratePacket.perform(%Oban.Job{
          args: %{
            "scene_id" => scene,
            "beat" => 2,
            "character_id" => @ghost,
            "packet_id" => BeatOps.packet_id(scene, 2, @ghost),
            "beat_ref" => BeatOps.beat_ref(scene, 2),
            "chain" => true,
            "provider" => @stub
          }
        })
      end)

      beat_events = stored(BeatOps.beat_ref(scene, 2))
      assert Enum.any?(beat_events, &match?(%PacketFailed{character_id: @ghost}, &1))
      refute Enum.any?(beat_events, &match?(%PacketRecorded{character_id: @ghost}, &1))
    end

    test "is surfaced to the author as a non-retryable failure" do
      scene = setup_scene(["227"])
      stub_director_casting(["227"])

      :ok =
        App.dispatch(%OpenBeat{
          beat_ref: BeatOps.beat_ref(scene, 2),
          scene_id: scene,
          beat: 2,
          cast: [@ghost]
        })

      Oban.Testing.with_testing_mode(:inline, fn ->
        GeneratePacket.perform(%Oban.Job{
          args: %{
            "scene_id" => scene,
            "beat" => 2,
            "character_id" => @ghost,
            "packet_id" => BeatOps.packet_id(scene, 2, @ghost),
            "beat_ref" => BeatOps.beat_ref(scene, 2),
            "chain" => true,
            "provider" => @stub
          }
        })
      end)

      row = Failure |> Polyphony.Repo.all() |> Enum.find(&(&1.subject == @ghost))
      assert row.kind == "rejected"
      refute row.retryable
      assert row.reason =~ "not_a_member"
    end
  end
end
