defmodule Polyphony.Authoring.Effective do
  @moduledoc """
  Loads canon arc and folds it into the sheet / world bible that generation sees
  (§2.8) — the wiring that turns arc review from a proposal queue into effect.

  Both `EffectiveSheet` and `EffectiveWorldBible` are pure folds; this is the thin
  layer that fetches the campaign's *canon* entries (`ReadModels.ArcEntry`) and
  applies them, so every context-materialization site (scene-open seed and cold
  rebuild, character and Director) reads the same effective inputs from one place.
  """

  alias Polyphony.Repo
  alias Polyphony.ReadModels.{ArcEntry, SceneSummary}
  alias Polyphony.Authoring.{CharacterSheet, WorldBible, EffectiveSheet, EffectiveWorldBible}

  @doc "The character's sheet with their canon arc applied."
  @spec sheet(CharacterSheet.t(), term(), module()) :: CharacterSheet.t()
  def sheet(%CharacterSheet{} = raw, character_id, repo \\ Repo) do
    EffectiveSheet.apply(raw, ArcEntry.canon_for_character(repo, character_id))
  end

  @doc """
  The character's sheet as it stood **at the close of `scene_id`** — the sheet
  scrubber's read (§2.14).

  Folds only the canon arc that had been extracted by then: entries whose
  `source_scene_id` is that scene or an earlier stop in the character's own
  chronology (`scene_stops/2`). Arc from a *later* scene is left out, which is the
  whole point; arc from a scene that hasn't closed is left out too, because there is
  no stop for it and it therefore belongs after every stop that exists.

  Entries with **no** source scene — hand-authored canon rather than something play
  extracted — always apply. They aren't in the chronology at all, so excluding them
  would make the newest stop disagree with `sheet/3`, and the last stop has to be
  the sheet you actually have.

  `scene_id` of `nil`, or a scene that isn't one of this character's stops, gives
  the sheet as authored plus that scene-less canon. Degrading toward *less* arc is
  deliberate: this read backs a read-only preview, where showing more than the
  caller asked for is a spoiler and showing less is merely stale.
  """
  @spec sheet_as_of(CharacterSheet.t(), term(), term() | nil, module()) :: CharacterSheet.t()
  def sheet_as_of(%CharacterSheet{} = raw, character_id, scene_id, repo \\ Repo) do
    through = stops_through(repo, character_id, scene_id)

    entries =
      repo
      |> ArcEntry.canon_for_character(character_id)
      |> Enum.filter(fn entry ->
        is_nil(entry.source_scene_id) or MapSet.member?(through, to_string(entry.source_scene_id))
      end)

    EffectiveSheet.apply(raw, entries)
  end

  @doc """
  The scrubber's stops: the scenes this character has closed, oldest first.

  One stop per closed scene, because arc is extracted at scene close and that is the
  only resolution the history has. Each is `%{scene_id:, summary:, closed_at:}`, so
  a stop can be labelled without a second read.
  """
  @spec scene_stops(term(), module()) :: [map()]
  def scene_stops(character_id, repo \\ Repo),
    do: SceneSummary.closed_scenes_for(repo, character_id)

  defp stops_through(_repo, _character_id, nil), do: MapSet.new()

  defp stops_through(repo, character_id, scene_id) do
    sid = to_string(scene_id)
    ids = repo |> SceneSummary.closed_scenes_for(character_id) |> Enum.map(& &1.scene_id)

    case Enum.find_index(ids, &(&1 == sid)) do
      nil -> MapSet.new()
      i -> ids |> Enum.take(i + 1) |> MapSet.new()
    end
  end

  @doc """
  The world bible with the campaign's canon world arc applied. `reach` is `:all`
  (omniscient) or a scene `location_id` (global + local-at-that-place). A nil
  `campaign_id` or bible degrades gracefully.
  """
  @spec world_bible(WorldBible.t() | nil, term(), :all | String.t() | nil, module()) ::
          WorldBible.t()
  def world_bible(raw, campaign_id, reach \\ :all, repo \\ Repo) do
    bible = raw || %WorldBible{}
    entries = if campaign_id, do: ArcEntry.canon_for_world(repo, campaign_id), else: []
    EffectiveWorldBible.apply(bible, entries, reach)
  end
end
