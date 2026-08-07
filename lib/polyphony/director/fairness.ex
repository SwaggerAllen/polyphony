defmodule Polyphony.Director.Fairness do
  @moduledoc """
  The casting fairness heuristic (§10): track how much each character has spoken
  recently in a scene and show it to the Director, so one character doesn't
  dominate the beat.

  A pure projection over the log — it counts `SpeechUttered` per speaker in a
  scene. The Director consumes the counts as advisory input to casting; it is not
  a hard constraint.
  """

  alias PolyphonyCore.Events.SpeechUttered

  @doc """
  Speak counts `%{character_id => count}` for `scene_id`, optionally limited to
  the most recent `:since_beat`.
  """
  @spec speak_counts(Enumerable.t(), term(), keyword()) :: %{term() => non_neg_integer()}
  def speak_counts(events, scene_id, opts \\ []) do
    since = Keyword.get(opts, :since_beat, 0)

    events
    |> Enum.filter(fn
      %SpeechUttered{scene_id: ^scene_id, beat: beat} -> beat >= since
      _ -> false
    end)
    |> Enum.reduce(%{}, fn %SpeechUttered{speaker_id: s}, acc ->
      Map.update(acc, s, 1, &(&1 + 1))
    end)
  end

  @doc "Order character ids least-recently-spoken first — a casting suggestion."
  @spec least_spoken_first([term()], %{term() => non_neg_integer()}) :: [term()]
  def least_spoken_first(character_ids, counts) do
    Enum.sort_by(character_ids, &Map.get(counts, &1, 0))
  end
end
