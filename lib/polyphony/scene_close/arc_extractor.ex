defmodule Polyphony.SceneClose.ArcExtractor do
  @moduledoc """
  Arc extraction at scene close (§6.2): one call per participating character,
  asking what durably changed or surfaced — from *that character's filtered
  stream*.

  Two guards come with the territory:

    * Whole-scene context is what interpretation needs, and scene closes are
      infrequent, so this runs at close, never per turn.
    * **The extraction trap**: distinguish world truth *about* the character from
      another character's *belief* about them. The prompt is scoped to the
      character's own filtered view and framed around "what is now true of you",
      so A's conclusion that B is lying stays in A's knowledge, not B's arc.

  Everything comes back `:proposed` — the review gate decides canon.
  """

  alias Polyphony.LLM.Provider
  alias PolyphonyCore.{Visibility, EventText}
  alias Polyphony.SceneClose.ArcSchema

  @doc "Extract proposed arc entries for `character_id`. Returns `{:ok, [ArcEntry]}`."
  @spec extract(Enumerable.t(), term(), keyword()) :: {:ok, list()} | {:error, term()}
  def extract(events, character_id, opts \\ []) do
    provider = Keyword.get(opts, :provider) || Provider.default()
    filtered = Visibility.project(events, {:character, character_id})

    messages = [
      %{role: "system", content: system_prompt(character_id)},
      %{role: "user", content: EventText.render(filtered)}
    ]

    call_opts = Keyword.merge(Keyword.take(opts, [:respond_with, :model]), response: :arc)

    metered =
      [provider: provider] ++
        call_opts ++ Keyword.take(opts, [:user_id, :campaign_id, :usage_kind])

    with {:ok, text} <- Polyphony.LLM.call(messages, metered),
         {:ok, data} when is_map(data) <- Jason.decode(text),
         {:ok, entries} <- ArcSchema.parse(data, source_scene_id: opts[:source_scene_id]) do
      {:ok, Enum.map(entries, &%{&1 | source_scene_id: opts[:source_scene_id]})}
    else
      {:error, %Ecto.Changeset{}} -> {:error, :invalid_arc}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_arc}
      {:ok, _non_object} -> {:error, :invalid_arc}
      other -> other
    end
  end

  # Every proposal carries its **reason** — what in the scene caused it. The design's
  # argument is that this is what makes accepting quick: an author can check the
  # reasoning without going back and rereading, so a proposal that can't say why is one
  # they have to earn twice.
  defp system_prompt(id),
    do:
      "You are extracting durable changes for #{id} after a scene. List only what is now " <>
        "TRUE of #{id} (a discovery that was always true but unstated, or a revision of something " <>
        "authored) — never another character's belief about #{id}. Use kind \"release\" when a " <>
        "line #{id} held gave way during the scene, and name it in \"released_topic\". For " <>
        "EVERY entry give a \"reason\": the specific thing in this scene that caused it, in one " <>
        "sentence, concrete enough that the author can recognise the moment. Respond as JSON: " <>
        ~s({"entries":[{"kind":"discovery|revision|release","sheet_field":null,) <>
        ~s("released_topic":null,"statement":"...","reason":"..."}]}.)
end
