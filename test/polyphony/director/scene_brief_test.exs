defmodule Polyphony.Director.SceneBriefTest do
  @moduledoc """
  The Director's omniscient scene brief (§9): world + premise + cast + cross-scene
  summaries frozen at scene open, then the full token-budgeted transcript per beat.
  """
  use ExUnit.Case, async: false

  alias Polyphony.App
  alias Polyphony.Authoring.{WorldBible, CharacterSheet}
  alias Polyphony.Director.SceneBrief
  alias Polyphony.TurnPacket
  alias Polyphony.TurnPacket.{Move, SelfState}
  alias Polyphony.Commands.{OpenScene, EnterCharacter, CommitPacket}
  alias Polyphony.Director.BeatOps

  defp scene, do: "sb-" <> Integer.to_string(System.unique_integer([:positive]))

  defp bible,
    do: %WorldBible{
      name: "Duskhaven",
      setting: "a drowned city",
      tone: "gothic",
      rules: ["no true resurrection"],
      starting_canon: ["the tide never fully recedes"]
    }

  defp sheet(name, premise), do: %CharacterSheet{name: name, premise: premise, voice: "clipped"}

  describe "materialize/2 (the frozen omniscient brief)" do
    test "renders world framing, premise, the whole cast, and distant omniscient summaries" do
      s = scene()

      ctx =
        SceneBrief.materialize(s,
          world_bible: bible(),
          premise: "A parley at the tideline.",
          roster: [sheet("Mira", "a tidewarden"), sheet("Otto", "a smuggler")],
          # StaticRetriever just echoes :distant_summaries — stands in for the
          # pgvector omniscient rows in a DB-free test.
          distant_summaries: [%{scene_id: "s0", text: "Earlier, the gate was breached."}]
        )

      assert ctx.prefix =~ "World: Duskhaven"
      assert ctx.prefix =~ "Setting: a drowned city"
      assert ctx.prefix =~ "no true resurrection"
      assert ctx.prefix =~ "Scene: A parley at the tideline."
      assert ctx.prefix =~ "Mira — a tidewarden"
      assert ctx.prefix =~ "Otto — a smuggler"
      assert ctx.prefix =~ "the gate was breached"
    end

    test "is cached and surfaced in the Director's messages" do
      s = scene()
      SceneBrief.materialize(s, world_bible: bible(), premise: "P.", roster: [sheet("Mira", "x")])

      [_system, %{content: user}] = SceneBrief.messages(s, ["Mira"])
      assert user =~ "World: Duskhaven"
      assert user =~ "Mira"
    end
  end

  describe "note_character/2 (mid-scene entry)" do
    test "folds a newcomer's identity into the cached brief" do
      s = scene()
      SceneBrief.materialize(s, premise: "P.", roster: [sheet("Mira", "a warden")])
      SceneBrief.note_character(s, sheet("Bram", "a latecomer"))

      [_system, %{content: user}] = SceneBrief.messages(s, ["Mira", "Bram"])
      assert user =~ "Mira — a warden"
      assert user =~ "Bram — a latecomer"
    end

    test "seeds a minimal brief when none was materialized" do
      s = scene()
      SceneBrief.note_character(s, sheet("Solo", "the only one"))

      [_system, %{content: user}] = SceneBrief.messages(s, ["Solo"])
      assert user =~ "Solo — the only one"
    end
  end

  describe "messages/3 (per-beat assembly)" do
    test "names the present roster and the cast instruction even with no brief" do
      s = scene()
      [%{content: system}, %{content: user}] = SceneBrief.messages(s, ["Mira", "Otto"])

      assert system =~ "Director"
      assert user =~ "Mira"
      assert user =~ "Otto"
      assert user =~ "Cast the characters who should act"
      assert user =~ "Use these exact ids"
    end

    test "an empty roster reads empty rather than being omitted" do
      s = scene()
      [_system, %{content: user}] = SceneBrief.messages(s, [])
      assert user =~ "no characters are present"
    end

    test "the caller's system message (content register etc.) is used verbatim" do
      s = scene()

      [%{content: system}, _user] =
        SceneBrief.messages(s, ["Mira"], system: "CUSTOM DIRECTOR LINE")

      assert system == "CUSTOM DIRECTOR LINE"
    end

    test "includes the full omniscient transcript — thoughts and whispers too" do
      s = scene()
      :ok = App.dispatch(%OpenScene{scene_id: s, opened_beat: 0})
      :ok = App.dispatch(%EnterCharacter{scene_id: s, character_id: "mira", beat: 1})

      packet = %TurnPacket{
        moves: [
          %Move{seq: 1, type: :thought, content: "I must not flinch."},
          %Move{seq: 2, type: :speech, content: "State your business."}
        ],
        self_state: %SelfState{}
      }

      :ok =
        App.dispatch(%CommitPacket{
          scene_id: s,
          character_id: "mira",
          beat: 1,
          packet_id: BeatOps.packet_id(s, 1, "mira"),
          packet: packet,
          edited: true
        })

      [_system, %{content: user}] = SceneBrief.messages(s, ["mira"])
      # The Director is omniscient: the interior thought is visible to it.
      assert user =~ "mira thinks: I must not flinch."
      assert user =~ "State your business."
    end
  end
end
