defmodule Polyphony.Director.Decision do
  @moduledoc """
  The Director's Stage-2 output (§10) — **one** structured decision per beat, so
  all of it is internally consistent (casting that doesn't know how proposals
  were ruled produces incoherent beats).

  Fields:

    * `proposal_rulings` — accept/reject per forwarded proposal, with a reason
    * `cast` — ordered character ids, each with an optional pacing note
    * `world_events` — non-character occurrences, scene-scoped (also how
      rejections surface in-fiction)
    * `scene_actions` — open/close/move characters between scenes
    * `control` — `:continue` or `:yield_to_user`, plus optional `search_need`

  The one hard casting rule is enforced here (§10 "cast, don't script"): a pacing
  note is a directive at most and **must not contain dialogue**. We reject a note
  carrying a quotation mark — the moment the Director writes lines, characters
  stop being independent.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    embeds_many :proposal_rulings, Ruling, primary_key: false do
      field(:actor_id, :string)
      field(:accept, :boolean)
      field(:reason, :string)
    end

    embeds_many :cast, CastMember, primary_key: false do
      field(:character_id, :string)
      field(:pacing_note, :string)
    end

    embeds_many :world_events, WorldEvent, primary_key: false do
      field(:scene_id, :string)
      field(:content, :string)
    end

    embeds_many :scene_actions, SceneAction, primary_key: false do
      field(:action, Ecto.Enum, values: [:open, :close, :move])
      field(:scene_id, :string)
      field(:character_id, :string)
      field(:to_scene_id, :string)
      field(:premise, :string)
    end

    field(:control, Ecto.Enum, values: [:continue, :yield_to_user])
    field(:search_need, :string)
  end

  @pacing_note_max 160

  @doc "Cast raw JSON into a validated changeset."
  def changeset(data) when is_map(data) do
    %__MODULE__{}
    |> cast(data, [:control, :search_need])
    |> validate_required([:control])
    |> cast_embed(:proposal_rulings, with: &ruling_changeset/2)
    |> cast_embed(:cast, with: &cast_member_changeset/2)
    |> cast_embed(:world_events, with: &world_event_changeset/2)
    |> cast_embed(:scene_actions, with: &scene_action_changeset/2)
  end

  defp ruling_changeset(r, params) do
    r
    |> cast(params, [:actor_id, :accept, :reason])
    |> validate_required([:actor_id, :accept])
  end

  defp cast_member_changeset(c, params) do
    c
    |> cast(params, [:character_id, :pacing_note])
    |> validate_required([:character_id])
    |> validate_length(:pacing_note, max: @pacing_note_max)
    |> validate_no_dialogue()
  end

  # "Cast, don't script" (§10): a pacing note may direct ("brief", "don't answer
  # yet") but must never contain a line of dialogue. A quotation mark is the tell.
  defp validate_no_dialogue(changeset) do
    case get_field(changeset, :pacing_note) do
      note when is_binary(note) ->
        if String.contains?(note, ["\"", "“", "”"]) do
          add_error(changeset, :pacing_note, "pacing notes must not contain dialogue")
        else
          changeset
        end

      _ ->
        changeset
    end
  end

  defp world_event_changeset(w, params) do
    w
    |> cast(params, [:scene_id, :content])
    |> validate_required([:content])
  end

  defp scene_action_changeset(s, params) do
    s
    |> cast(params, [:action, :scene_id, :character_id, :to_scene_id, :premise])
    |> validate_required([:action])
  end

  @doc "Cast, validate, and apply — returning the decision struct or the changeset."
  @spec parse(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def parse(data) do
    cs = changeset(data)
    if cs.valid?, do: {:ok, apply_changes(cs)}, else: {:error, cs}
  end

  @type t :: %__MODULE__{}
end
