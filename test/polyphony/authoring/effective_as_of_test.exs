defmodule Polyphony.Authoring.EffectiveAsOfTest do
  @moduledoc """
  Sheet time travel (`completed-roadmap.md` §2.14) — reading a sheet as it stood at
  the close of a past scene.

  The history was already recorded: `arc_entries` carries `source_scene_id`, so
  every canon revision knows which scene produced it. What was missing was the read
  — `Effective.sheet/3` folds *all* canon with no "as of". This pins the fold's
  cut-off and, more importantly, the three edge cases where a naive cut-off gives a
  wrong answer:

    * **hand-authored canon has no source scene**, so it can't be ordered — and
      dropping it would make the newest stop disagree with `sheet/3`, which would
      mean the scrubber's right-hand end wasn't the sheet you actually have;
    * **an open scene has no stop**, so its arc belongs after every stop there is;
    * **an unrecognised scene degrades toward less arc**, because this read backs a
      read-only preview and showing more than was asked for is a spoiler.

  One stop per *closed* scene, because arc is extracted at scene close: there is
  nothing to wind back to between two closes.
  """
  use ExUnit.Case, async: true

  alias Polyphony.Repo
  alias Polyphony.Authoring.{CharacterSheet, Effective}
  alias Polyphony.ReadModels.{ArcEntry, SceneSummary}
  alias Polyphony.Authoring.ArcEntry, as: Arc
  alias Polyphony.SceneClose.MockEmbedder

  @wren "wren-ashgrove"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp embed(text), do: elem(MockEmbedder.embed(text), 1)

  defp close!(scene_id, summary) do
    SceneSummary.put(Repo, scene_id, @wren, summary, embed(summary))
    scene_id
  end

  defp canon!(field, statement, opts) do
    entry =
      %Arc{
        kind: :revision,
        sheet_field: field,
        statement: statement,
        beat: opts[:beat],
        source_scene_id: opts[:scene],
        status: :proposed
      }

    row = ArcEntry.put(Repo, entry, @wren)
    ArcEntry.accept(Repo, row.id)
  end

  defp sheet, do: %CharacterSheet{name: "Wren Ashgrove", temperament: "Guarded."}

  describe "scene_stops/2" do
    test "one stop per closed scene, oldest first" do
      close!("S1", "She rang the bell.")
      close!("S2", "She did not.")
      close!("S3", "Someone else did.")

      assert ["S1", "S2", "S3"] = Effective.scene_stops(@wren, Repo) |> Enum.map(& &1.scene_id)
    end

    test "a stop carries its own label, so the scrubber needs no second read" do
      close!("S1", "She rang the bell.")

      assert [%{scene_id: "S1", summary: "She rang the bell.", closed_at: %NaiveDateTime{}}] =
               Effective.scene_stops(@wren, Repo)
    end

    test "an open scene is not a stop — there is nothing to wind back to yet" do
      close!("S1", "She rang the bell.")
      assert Effective.scene_stops(@wren, Repo) |> Enum.map(& &1.scene_id) == ["S1"]
    end

    test "a character with no closed scenes has no stops, which is not an error" do
      assert Effective.scene_stops(@wren, Repo) == []
    end
  end

  describe "sheet_as_of/4" do
    setup do
      close!("S1", "She rang the bell.")
      close!("S2", "She stopped.")
      close!("S3", "She told him why.")

      canon!("temperament", "Wary, but reachable.", scene: "S1", beat: 2)
      canon!("temperament", "Openly frightened.", scene: "S2", beat: 5)
      canon!("temperament", "Unburdened.", scene: "S3", beat: 9)
      :ok
    end

    test "winds the sheet back to how it stood at that scene's close" do
      assert Effective.sheet_as_of(sheet(), @wren, "S1", Repo).temperament ==
               "Wary, but reachable."

      assert Effective.sheet_as_of(sheet(), @wren, "S2", Repo).temperament == "Openly frightened."
      assert Effective.sheet_as_of(sheet(), @wren, "S3", Repo).temperament == "Unburdened."
    end

    test "arc from a later scene is not visible from an earlier stop" do
      as_of = Effective.sheet_as_of(sheet(), @wren, "S1", Repo)
      refute as_of.temperament == "Unburdened."
    end

    test "the newest stop agrees with the plain effective sheet" do
      assert Effective.sheet_as_of(sheet(), @wren, "S3", Repo) ==
               Effective.sheet(sheet(), @wren, Repo)
    end

    test "nil is 'before any of it' — the sheet as authored" do
      assert Effective.sheet_as_of(sheet(), @wren, nil, Repo).temperament == "Guarded."
    end
  end

  describe "the edges a naive cut-off gets wrong" do
    test "hand-authored canon has no source scene, so it applies at every stop" do
      close!("S1", "She rang the bell.")
      canon!("voice", "Clipped, and quieter than she means to be.", beat: nil)
      canon!("temperament", "Wary, but reachable.", scene: "S1", beat: 2)

      as_of = Effective.sheet_as_of(sheet(), @wren, "S1", Repo)
      assert as_of.voice == "Clipped, and quieter than she means to be."
      assert as_of == Effective.sheet(sheet(), @wren, Repo)
    end

    test "arc from a scene still open belongs after every stop that exists" do
      close!("S1", "She rang the bell.")
      canon!("temperament", "Wary, but reachable.", scene: "S1", beat: 2)
      canon!("temperament", "Mid-scene, and not yet settled.", scene: "S2-open", beat: 4)

      # The last stop still reads as of S1's close...
      assert Effective.sheet_as_of(sheet(), @wren, "S1", Repo).temperament ==
               "Wary, but reachable."

      # ...while the live sheet has moved on.
      assert Effective.sheet(sheet(), @wren, Repo).temperament ==
               "Mid-scene, and not yet settled."
    end

    test "an unrecognised scene degrades toward less arc, never more" do
      close!("S1", "She rang the bell.")
      canon!("temperament", "Wary, but reachable.", scene: "S1", beat: 2)

      assert Effective.sheet_as_of(sheet(), @wren, "S9", Repo).temperament == "Guarded."
    end

    test "another character's stops don't cut this character's arc" do
      SceneSummary.put(Repo, "S1", "halloran", "He watched.", embed("watched"))
      canon!("temperament", "Wary, but reachable.", scene: "S1", beat: 2)

      # Wren never closed S1 herself, so it isn't one of her stops.
      assert Effective.scene_stops(@wren, Repo) == []
      assert Effective.sheet_as_of(sheet(), @wren, "S1", Repo).temperament == "Guarded."
    end

    test "a proposal that was never accepted is absent from every stop" do
      close!("S1", "She rang the bell.")

      ArcEntry.put(
        Repo,
        %Arc{
          kind: :revision,
          sheet_field: "temperament",
          statement: "Reckless.",
          beat: 2,
          source_scene_id: "S1",
          status: :proposed
        },
        @wren
      )

      assert Effective.sheet_as_of(sheet(), @wren, "S1", Repo).temperament == "Guarded."
    end
  end
end
