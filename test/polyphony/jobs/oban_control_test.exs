defmodule Polyphony.Jobs.ObanControlTest do
  @moduledoc """
  Control modes on the **Oban async path** (§A1/§A2): the durable beat loop honors
  the declared turn order, generates autonomous slots through the job chain, and
  **pauses** on a user-controlled or assisted slot — resuming via `BeatDriver`. The
  walk decision lives in the pure `BeatWalk`. Run in Oban's `:inline` mode with the
  Mock provider.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{App, Repo, Context, Drafts}
  alias PolyphonyCore.Packets
  alias Polyphony.Context.Store
  alias Polyphony.Authoring.CharacterSheet
  alias Polyphony.Commands.{OpenScene, EnterCharacter, SetControlMode, DeclareTurnOrder}
  alias Polyphony.Director.BeatDriver
  alias Polyphony.Jobs.RunBeat
  alias PolyphonyCore.Events.{ThoughtOccurred, BeatClosed}
  alias Polyphony.TurnPacket
  alias Polyphony.TurnPacket.{Move, SelfState}

  @mock "Elixir.Polyphony.LLM.Mock"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp stored(stream),
    do: App |> Commanded.EventStore.stream_forward(stream) |> Enum.map(& &1.data)

  defp canonical(s), do: s |> stored() |> Packets.canonical()

  defp thought_chars(s),
    do: for(%ThoughtOccurred{character_id: c} <- canonical(s), do: c) |> Enum.uniq()

  defp setup_scene(members) do
    scene = "obc-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})

    for m <- members do
      :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: m, beat: 1})
      sheet = %CharacterSheet{name: m, premise: "#{m} present.", voice: "plain"}

      Store.put(
        scene,
        m,
        Context.materialize(scene_id: scene, character_id: m, sheet: sheet, premise: "A hall.")
      )
    end

    scene
  end

  defp user_packet(mark) do
    %TurnPacket{
      moves: [
        %Move{seq: 1, type: :thought, content: "#{mark}-thought"},
        %Move{seq: 2, type: :speech, content: "#{mark}-speech"}
      ],
      self_state: %SelfState{}
    }
  end

  defp inline(fun), do: Oban.Testing.with_testing_mode(:inline, fun)

  test "the async chain pauses on a user-controlled slot and resumes on the user's turn" do
    scene = setup_scene(["alice", "bram", "cara"])

    :ok =
      App.dispatch(%SetControlMode{
        scene_id: scene,
        character_id: "bram",
        control: "user_controlled"
      })

    :ok =
      App.dispatch(%DeclareTurnOrder{scene_id: scene, beat: 2, order: ["alice", "bram", "cara"]})

    inline(fn ->
      RunBeat.enqueue(%{
        "scene_id" => scene,
        "beat" => 2,
        "provider" => @mock,
        "control_hint" => "yield_to_user"
      })
    end)

    # Alice (autonomous) ran through the chain; it then paused at bram. cara hasn't run.
    assert thought_chars(scene) == ["alice"]
    refute Enum.any?(stored("#{scene}-b2"), &match?(%BeatClosed{}, &1))

    # The user submits bram's turn → the chain resumes, generates cara, and closes.
    inline(fn ->
      BeatDriver.submit_user_turn(scene, 2, "bram", user_packet("bram"), provider: @mock)
    end)

    assert Enum.sort(thought_chars(scene)) == ["alice", "bram", "cara"]

    assert %BeatClosed{completed: ["alice", "bram", "cara"]} =
             Enum.find(stored("#{scene}-b2"), &match?(%BeatClosed{}, &1))
  end

  test "two user-controlled slots pause twice; a pass settles the beat" do
    scene = setup_scene(["alice", "bram", "cara"])

    :ok =
      App.dispatch(%SetControlMode{
        scene_id: scene,
        character_id: "alice",
        control: "user_controlled"
      })

    :ok =
      App.dispatch(%SetControlMode{
        scene_id: scene,
        character_id: "cara",
        control: "user_controlled"
      })

    :ok =
      App.dispatch(%DeclareTurnOrder{scene_id: scene, beat: 2, order: ["alice", "bram", "cara"]})

    # First slot is user-controlled → immediate pause, nothing generated.
    inline(fn -> RunBeat.enqueue(%{"scene_id" => scene, "beat" => 2, "provider" => @mock}) end)
    assert thought_chars(scene) == []

    # User writes alice → bram (autonomous) generates → pauses again for cara.
    inline(fn ->
      BeatDriver.submit_user_turn(scene, 2, "alice", user_packet("alice"), provider: @mock)
    end)

    assert Enum.sort(thought_chars(scene)) == ["alice", "bram"]
    refute Enum.any?(stored("#{scene}-b2"), &match?(%BeatClosed{}, &1))

    # User skips cara → the beat settles and closes.
    inline(fn -> BeatDriver.pass_turn(scene, 2, "cara", provider: @mock) end)

    assert %BeatClosed{passed: ["cara"]} =
             Enum.find(stored("#{scene}-b2"), &match?(%BeatClosed{}, &1))
  end

  test "an assisted slot pauses with a pending draft; accept resumes the chain" do
    scene = setup_scene(["alice", "bram", "cara"])

    :ok =
      App.dispatch(%SetControlMode{scene_id: scene, character_id: "bram", control: "assisted"})

    :ok =
      App.dispatch(%DeclareTurnOrder{scene_id: scene, beat: 2, order: ["alice", "bram", "cara"]})

    inline(fn ->
      RunBeat.enqueue(%{"scene_id" => scene, "beat" => 2, "provider" => @mock})
    end)

    # Alice committed; bram is a pending draft (not a fact); cara hasn't run.
    assert thought_chars(scene) == ["alice"]
    assert [%{character_id: "bram"} = draft] = Drafts.list_open(scene, repo: Repo)

    inline(fn -> BeatDriver.accept_draft(draft.id, provider: @mock, repo: Repo) end)

    assert Enum.sort(thought_chars(scene)) == ["alice", "bram", "cara"]
    assert Drafts.list_open(scene, repo: Repo) == []
  end

  test "discarding an assisted draft passes the slot and the chain continues" do
    scene = setup_scene(["alice", "bram", "cara"])

    :ok =
      App.dispatch(%SetControlMode{scene_id: scene, character_id: "bram", control: "assisted"})

    :ok =
      App.dispatch(%DeclareTurnOrder{scene_id: scene, beat: 2, order: ["alice", "bram", "cara"]})

    inline(fn -> RunBeat.enqueue(%{"scene_id" => scene, "beat" => 2, "provider" => @mock}) end)
    [draft] = Drafts.list_open(scene, repo: Repo)

    inline(fn -> BeatDriver.discard_draft(draft.id, provider: @mock, repo: Repo) end)

    # bram passed (never committed); alice and cara acted; beat closed.
    assert Enum.sort(thought_chars(scene)) == ["alice", "cara"]

    assert %BeatClosed{passed: ["bram"]} =
             Enum.find(stored("#{scene}-b2"), &match?(%BeatClosed{}, &1))
  end

  test "the async chain honors a user-declared order that drops a character" do
    scene = setup_scene(["alice", "bram", "cara"])
    :ok = App.dispatch(%DeclareTurnOrder{scene_id: scene, beat: 2, order: ["alice", "cara"]})

    inline(fn -> RunBeat.enqueue(%{"scene_id" => scene, "beat" => 2, "provider" => @mock}) end)

    assert Enum.sort(thought_chars(scene)) == ["alice", "cara"]
    refute "bram" in thought_chars(scene)
  end
end
