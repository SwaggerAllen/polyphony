defmodule Polyphony.SceneClose.WorldArcExtractor do
  @moduledoc """
  World-arc extraction at scene close (§2.8): one call per scene, asking what
  durably changed about the **world** — over the *unfiltered* stream, since world
  facts are not anyone's private view (the counterpart to `ArcExtractor`, which
  runs per-character over a filtered stream).

  The model also classifies each fact's reach — **global** (everyone comes to know)
  vs **local** (known where it happened first) — which becomes the propagation rule.
  Everything comes back `:proposed`; the review gate decides canon.
  """

  alias Polyphony.{EventText, LLM.Provider}
  alias Polyphony.SceneClose.WorldArcSchema

  @doc """
  Extract proposed world-arc entries from a scene's full event stream. Returns
  `{:ok, [WorldArcEntry]}`. Opts: `:source_scene_id`, `:location_id` (stamped onto
  local entries), plus the usual `:provider`/`:model`/metering keys.
  """
  @spec extract(Enumerable.t(), keyword()) :: {:ok, list()} | {:error, term()}
  def extract(events, opts \\ []) do
    provider = Keyword.get(opts, :provider) || Provider.default()

    messages = [
      %{role: "system", content: system_prompt()},
      %{role: "user", content: EventText.render(events)}
    ]

    call_opts = Keyword.merge(Keyword.take(opts, [:respond_with, :model]), response: :world_arc)

    metered =
      [provider: provider] ++
        call_opts ++ Keyword.take(opts, [:user_id, :campaign_id, :usage_kind])

    with {:ok, text} <- Polyphony.LLM.call(messages, metered),
         {:ok, data} when is_map(data) <- Jason.decode(text),
         {:ok, entries} <-
           WorldArcSchema.parse(data,
             source_scene_id: opts[:source_scene_id],
             location_id: opts[:location_id]
           ) do
      {:ok, entries}
    else
      {:error, %Ecto.Changeset{}} -> {:error, :invalid_arc}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_arc}
      {:ok, _non_object} -> {:error, :invalid_arc}
      other -> other
    end
  end

  defp system_prompt,
    do:
      "You are extracting durable changes to the WORLD after a scene — standing facts about " <>
        "the setting or its canon that are now TRUE and weren't before, not any character's " <>
        "private thoughts and not passing moments. For each, mark its reach: \"global\" if " <>
        "everyone in the world would come to know it, or \"local\" if it would be known first " <>
        "only where it happened. Respond as JSON: " <>
        ~s({"entries":[{"kind":"discovery|revision","scope":"global|local","statement":"..."}]}.)
end
