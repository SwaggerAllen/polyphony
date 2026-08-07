defmodule Polyphony.Generation.PacketSchema do
  @moduledoc """
  The structured-output contract for a character turn (§6.4) — the Ecto schema a
  generated packet is cast into and validated against before it becomes a domain
  `TurnPacket`.

  This is the role the brief assigns to Instructor: schema → validation → retry.
  Keeping it as a plain Ecto embedded schema means the same changeset rules run
  whether the text came from DeepInfra or a test stub, and the JSON-schema for
  the prompt can be derived from these fields. Structuring at the point of
  generation (not extracting prose afterward) is the §6.3 rule that makes the
  fold mechanical.

  Enforced rules:

    * **Moves capped at 1..5** (§6.4 "cap moves at 4-5"; given an array, models
      write ten and monopolize the beat).
    * **`addressed_to` / `:private` are speech-only** — they are meaningless on a
      thought or action and usually signal the model misused the field.
    * Every move needs a `seq`, a `type`, and non-empty `content`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @max_moves 5

  @primary_key false
  embedded_schema do
    embeds_many :moves, Move, primary_key: false do
      field(:seq, :integer)
      field(:type, Ecto.Enum, values: [:thought, :speech, :action])
      field(:content, :string)
      field(:addressed_to, {:array, :string}, default: [])
      field(:audibility, Ecto.Enum, values: [:normal, :private], default: :normal)
    end

    embeds_one :self_state, SelfState, primary_key: false do
      field(:mood_felt, :string)
      field(:demeanor, :string)
      field(:intention, :string)
      field(:attending_to, :string)
      field(:position, :string)
      field(:posture, :string)
    end
  end

  @doc "Cast raw (string-keyed) JSON into a validated changeset."
  def changeset(data) when is_map(data) do
    %__MODULE__{}
    |> cast(data, [])
    |> cast_embed(:moves, with: &move_changeset/2, required: true)
    |> cast_embed(:self_state, with: &self_state_changeset/2)
    |> validate_move_count()
  end

  defp validate_move_count(changeset) do
    moves = get_field(changeset, :moves) || []

    cond do
      moves == [] ->
        add_error(changeset, :moves, "at least one move is required")

      length(moves) > @max_moves ->
        add_error(changeset, :moves, "at most #{@max_moves} moves per packet")

      true ->
        changeset
    end
  end

  defp move_changeset(move, params) do
    move
    |> cast(drop_unknown_audibility(params), [:seq, :type, :content, :addressed_to, :audibility])
    |> validate_required([:seq, :type, :content])
    |> validate_change(:content, fn :content, c ->
      if String.trim(c) == "", do: [content: "must not be blank"], else: []
    end)
    |> normalize_speech_only_fields()
  end

  # addressed_to and :private audibility only belong on speech (§6.4). The model routinely
  # tags thoughts and actions with them anyway; rather than *reject* — which forces a
  # whole corrective re-generation on nearly every turn (see the beat log: every cast
  # member's first attempt round-trips) — normalize them away on non-speech moves. They
  # carry no meaning off a speech line: a thought's privacy comes from its type, and an
  # action is public narration. The stored packet still upholds the speech-only invariant.
  defp normalize_speech_only_fields(changeset) do
    case get_field(changeset, :type) do
      :speech ->
        changeset

      _ ->
        changeset
        |> put_change(:addressed_to, [])
        |> put_change(:audibility, :normal)
    end
  end

  defp self_state_changeset(state, params) do
    cast(state, params, [:mood_felt, :demeanor, :intention, :attending_to, :position, :posture])
  end

  @doc """
  Cast, validate, and convert to a domain `PolyphonyCore.TurnPacket`.

  Returns `{:ok, %TurnPacket{}}` or `{:error, changeset}` (whose errors feed the
  corrective retry in `Polyphony.Generation`).
  """
  @spec parse(map()) :: {:ok, PolyphonyCore.TurnPacket.t()} | {:error, Ecto.Changeset.t()}
  def parse(data) do
    changeset = changeset(data)

    if changeset.valid? do
      {:ok, to_turn_packet(apply_changes(changeset))}
    else
      {:error, changeset}
    end
  end

  defp to_turn_packet(%__MODULE__{moves: moves, self_state: state}) do
    %PolyphonyCore.TurnPacket{
      moves:
        Enum.map(moves, fn m ->
          %PolyphonyCore.TurnPacket.Move{
            seq: m.seq,
            type: m.type,
            content: m.content,
            addressed_to: m.addressed_to || [],
            audibility: m.audibility || :normal
          }
        end),
      self_state: to_self_state(state)
    }
  end

  defp to_self_state(nil), do: nil

  defp to_self_state(s) do
    %PolyphonyCore.TurnPacket.SelfState{
      mood_felt: s.mood_felt,
      demeanor: s.demeanor,
      intention: s.intention,
      attending_to: s.attending_to,
      position: s.position,
      posture: s.posture
    }
  end

  @doc "Human-readable validation errors, for the corrective retry prompt."
  def error_messages(%Ecto.Changeset{} = cs) do
    cs
    |> traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", err_value(v)) end)
    end)
    |> inspect()
  end

  # An Ecto.Enum cast error carries the parameterized `:type` tuple as an opt, which has
  # no `String.Chars` — a bare `to_string/1` crashes the whole (async) generation task on
  # any bad enum value. Fall back to `inspect/1` for anything not plainly stringable.
  defp err_value(v) when is_binary(v) or is_atom(v) or is_number(v), do: to_string(v)
  defp err_value(v), do: inspect(v)

  # The model occasionally emits an audibility outside the enum ("public", "loud", …).
  # Drop it so the move defaults to :normal rather than failing the whole packet on a cast
  # error (which would otherwise force a corrective re-generation). A speech move meant to
  # whisper still uses "private"; anything unrecognized is simply audible.
  defp drop_unknown_audibility(params) when is_map(params) do
    case params[:audibility] || params["audibility"] do
      v when v in [nil, "normal", "private", :normal, :private] -> params
      _ -> params |> Map.delete(:audibility) |> Map.delete("audibility")
    end
  end

  defp drop_unknown_audibility(params), do: params
end
