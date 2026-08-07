defmodule Polyphony.Ingest do
  @moduledoc """
  The user's ingestion path (§11): turn the user's *existing* prose into a
  `TurnPacket` by **segmenting and classifying**, never generating.

  The flow is deliberately two-step so the user stays in control:

      propose/2  → a %ProposedParse{} (segments + routed OOC), shown for review
      confirm/2  → the committed %TurnPacket{} plus any OOC to route to the Director

  Three §11 requirements live here:

    * **Verbatim integrity.** `verify_verbatim/2` asserts every segment's content
      is a span of the original prose, in order — the mechanical guard against a
      segmenter "improving" the user's words. A mis-parse of a movement silently
      changes membership and visibility for everyone, so the parse is *proposed*,
      not committed, until confirmed.
    * **OOC escape hatch.** `[OOC: …]` segments are split out and routed to the
      Director rather than committed as character moves.
    * **Self-state asymmetry.** For the user, silence = *unchanged* — the opposite
      of the AI snapshot-decay rule — so `merge_self_state/2` carries prior fields
      forward unless the prose (or a UI override) changes them.
  """

  alias Polyphony.Ingest.{Segment, HeuristicSegmenter}
  alias PolyphonyCore.TurnPacket
  alias PolyphonyCore.TurnPacket.{Move, SelfState}

  defmodule ProposedParse do
    @moduledoc "A segmentation awaiting user confirmation (§13 `parse.proposed`)."
    defstruct [:source, :segments, :character_id, :previous_self_state]

    @type t :: %__MODULE__{
            source: String.t(),
            segments: [Segment.t()],
            character_id: term(),
            previous_self_state: SelfState.t() | nil
          }
  end

  @doc """
  Segment `prose` into a `ProposedParse` for review.

  Options: `:segmenter` (default `HeuristicSegmenter`), `:roster`,
  `:character_id`, `:previous_self_state`. Returns `{:error, {:not_verbatim, …}}`
  if the segmenter altered the words.
  """
  @spec propose(String.t(), keyword()) :: {:ok, ProposedParse.t()} | {:error, term()}
  def propose(prose, opts \\ []) do
    segmenter = Keyword.get(opts, :segmenter, HeuristicSegmenter)
    roster = Keyword.get(opts, :roster, [])

    with {:ok, segments} <- segmenter.segment(prose, roster),
         :ok <- verify_verbatim(segments, prose) do
      {:ok,
       %ProposedParse{
         source: prose,
         segments: segments,
         character_id: Keyword.get(opts, :character_id),
         previous_self_state: Keyword.get(opts, :previous_self_state)
       }}
    end
  end

  @doc """
  Confirm a proposed parse (optionally with edited `:segments`) into a committed
  turn.

  Returns `%{packet: %TurnPacket{}, ooc: [String.t()]}` — the character moves as a
  packet, and the OOC lines to hand to the Director. Re-verifies verbatim on
  edited segments so a manual edit can't smuggle in a rewrite either.
  """
  @spec confirm(ProposedParse.t(), keyword()) ::
          {:ok, %{packet: TurnPacket.t(), ooc: [String.t()]}} | {:error, term()}
  def confirm(%ProposedParse{} = parse, opts \\ []) do
    segments = Keyword.get(opts, :segments, parse.segments)

    with :ok <- verify_verbatim(segments, parse.source) do
      {ooc, moves} = Enum.split_with(segments, &(&1.type == :ooc))

      packet = %TurnPacket{
        moves: to_moves(moves),
        self_state:
          merge_self_state(parse.previous_self_state, Keyword.get(opts, :inferred_self_state))
      }

      {:ok, %{packet: packet, ooc: Enum.map(ooc, & &1.content)}}
    end
  end

  @doc """
  Verify each segment's `content` is a verbatim span of `source`, appearing in
  order (non-overlapping). This is the "never rewrite" guarantee (§11).
  """
  @spec verify_verbatim([Segment.t()], String.t()) :: :ok | {:error, {:not_verbatim, Segment.t()}}
  def verify_verbatim(segments, source) do
    result =
      Enum.reduce_while(segments, {:ok, 0}, fn seg, {:ok, pos} ->
        rest = binary_part(source, pos, byte_size(source) - pos)

        case seg.content != "" and :binary.match(rest, seg.content) do
          {idx, len} -> {:cont, {:ok, pos + idx + len}}
          _ -> {:halt, {:error, {:not_verbatim, seg}}}
        end
      end)

    case result do
      {:ok, _pos} -> :ok
      error -> error
    end
  end

  @doc """
  Merge an inferred self-state onto the previous one, carrying prior fields
  forward where the new one is silent (§11: for the user, silence = unchanged).
  """
  @spec merge_self_state(SelfState.t() | nil, SelfState.t() | nil) :: SelfState.t() | nil
  def merge_self_state(nil, nil), do: nil
  def merge_self_state(previous, nil), do: previous
  def merge_self_state(nil, inferred), do: inferred

  def merge_self_state(%SelfState{} = previous, %SelfState{} = inferred) do
    Map.merge(previous, Map.from_struct(inferred), fn _k, prev, new ->
      if is_nil(new), do: prev, else: new
    end)
  end

  defp to_moves(segments) do
    segments
    |> Enum.with_index(1)
    |> Enum.map(fn {seg, seq} ->
      %Move{
        seq: seq,
        type: seg.type,
        content: seg.content,
        addressed_to: seg.addressed_to || [],
        audibility: seg.audibility || :normal
      }
    end)
  end
end
