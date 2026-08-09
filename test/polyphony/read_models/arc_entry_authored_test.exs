defmodule Polyphony.ReadModels.ArcEntryAuthoredTest do
  @moduledoc """
  Authored arc entries as rows (STR-62): the new columns round-trip, the narrowed
  accept, the per-subject pending counts, and the per-row gate states.
  """
  use ExUnit.Case, async: false

  alias Polyphony.Repo
  alias Polyphony.Authoring.{ArcEntry, Audience, SceneGate, WorldArcEntry}
  alias Polyphony.ReadModels.ArcEntry, as: ArcRM
  alias Polyphony.ReadModels.Failure

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  test "an authored character entry round-trips every authoring column" do
    audience = %Audience{character_ids: ["p2"]}

    ArcRM.put(
      Repo,
      %ArcEntry{
        kind: :discovery,
        sheet_field: "facts",
        statement: "She has taken to carrying her father's key.",
        reason: "Scene 3 left it in her hand.",
        author: "allen",
        operation: :add,
        timing: :scene,
        source_scene_id: "sc-3",
        core: true,
        concealed: true,
        audience: audience
      },
      "wren"
    )

    assert [domain] = ArcRM.list_proposed(Repo, "wren")
    ArcRM.accept(Repo, domain.id)

    assert [
             %ArcEntry{
               author: "allen",
               operation: :add,
               timing: :scene,
               core: true,
               concealed: true,
               audience: ^audience
             }
           ] = ArcRM.canon_for_character(Repo, "wren")
  end

  test "a release proposal keeps its written condition and whether it was met" do
    ArcRM.put(
      Repo,
      %ArcEntry{
        kind: :release,
        statement: "Covering for her father — it broke.",
        released_topic: "Can't stop covering for her father",
        line_condition: "Someone she loves is going to be hurt by the silence.",
        condition_met: false
      },
      "wren"
    )

    assert [row] = ArcRM.list_proposed(Repo, "wren")
    assert row.condition_met == false
    assert row.line_condition =~ "hurt by the silence"
  end

  test "set_audience narrows and widens without deciding whether it is true" do
    row =
      ArcRM.put_world(
        Repo,
        %WorldArcEntry{
          kind: :discovery,
          scope: :global,
          statement: "The bell rang twice.",
          source_scene_id: "sc-3",
          status: :proposed
        },
        "camp-1"
      )

    ArcRM.set_audience(Repo, row.id, :there)

    # Still proposed: who knows is an audience, not a way of accepting or refusing.
    assert [%{status: "proposed", concealed: true}] = ArcRM.list_proposed_world(Repo, "camp-1")

    ArcRM.set_audience(Repo, row.id, :everyone)
    assert [%{concealed: false, audience: nil}] = ArcRM.list_proposed_world(Repo, "camp-1")

    ArcRM.set_audience(Repo, row.id, :there)
    ArcRM.accept(Repo, row.id)

    assert [%WorldArcEntry{concealed: true, audience: %Audience{scene: true}}] =
             ArcRM.canon_for_world(Repo, "camp-1")
  end

  test "proposed_counts answers many subjects at once, absent when clean" do
    for _ <- 1..2 do
      ArcRM.put(Repo, %ArcEntry{kind: :discovery, statement: "x"}, "wren")
    end

    ArcRM.put(Repo, %ArcEntry{kind: :discovery, statement: "y"}, "ilias")

    assert %{"wren" => 2, "ilias" => 1} == ArcRM.proposed_counts(Repo, ["wren", "ilias", "otto"])
  end

  describe "SceneGate.row_states/3" do
    test "every id gets a row; pending, failure and clean are told apart" do
      ArcRM.put(Repo, %ArcEntry{kind: :discovery, statement: "x"}, "wren")

      Failure.put(Repo, %{
        subject: "ilias",
        operation: "arc",
        kind: "transport",
        reason: "busy",
        worker: "Elixir.Polyphony.Jobs.ExtractArc",
        args: %{}
      })

      states = SceneGate.row_states("camp-1", ["wren", "ilias", "otto"], Repo)

      assert %{pending: 1, running: false, failure: nil} = states.characters["wren"]
      assert %{pending: 0, failure: %Failure{}} = states.characters["ilias"]
      assert %{pending: 0, running: false, failure: nil} = states.characters["otto"]
      assert states.world == 0
    end

    test "an unfinished ExtractArc job reads as still being worked out" do
      Oban.insert!(
        Polyphony.Jobs.ExtractArc.new(%{"scene_id" => "sc-1", "character_id" => "wren"})
      )

      states = SceneGate.row_states("camp-1", ["wren"], Repo)
      assert states.characters["wren"].running
    end

    test "a resolved failure no longer marks the row failed" do
      row =
        Failure.put(Repo, %{
          subject: "wren",
          operation: "arc",
          kind: "transport",
          reason: "busy",
          worker: "Elixir.Polyphony.Jobs.ExtractArc",
          args: %{}
        })

      {:ok, _} = Failure.resolve(Repo, row.id)

      states = SceneGate.row_states("camp-1", ["wren"], Repo)
      assert states.characters["wren"].failure == nil
    end
  end
end
