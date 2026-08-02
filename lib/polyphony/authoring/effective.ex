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
  alias Polyphony.ReadModels.ArcEntry
  alias Polyphony.Authoring.{CharacterSheet, WorldBible, EffectiveSheet, EffectiveWorldBible}

  @doc "The character's sheet with their canon arc applied."
  @spec sheet(CharacterSheet.t(), term(), module()) :: CharacterSheet.t()
  def sheet(%CharacterSheet{} = raw, character_id, repo \\ Repo) do
    EffectiveSheet.apply(raw, ArcEntry.canon_for_character(repo, character_id))
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
