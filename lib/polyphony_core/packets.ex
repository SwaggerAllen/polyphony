defmodule PolyphonyCore.Packets do
  @moduledoc """
  Packet-level helpers over a raw event stream — the one place that knows how a
  re-roll's `PacketSuperseded` markers reshape what a projection sees (§7, §12).

  Every read that feeds fiction to someone — a character's conditioning context,
  a viewer's broadcast, a scene-close summary — runs its events through
  `canonical/1` first. That drops both the superseded packets (by `packet_id`)
  and the markers themselves, so a re-rolled turn vanishes everywhere at once and
  no read site has to reason about re-rolls on its own.
  """

  alias PolyphonyCore.Events.PacketSuperseded

  @doc "The set of `packet_id`s that have been superseded by a re-roll."
  @spec superseded_ids([struct()]) :: MapSet.t()
  def superseded_ids(events) do
    for %PacketSuperseded{packet_id: id} <- events, is_binary(id), into: MapSet.new(), do: id
  end

  @doc """
  The canonical view of a stream: superseded packets and the `PacketSuperseded`
  markers removed. Everything else passes through in log order.
  """
  @spec canonical([struct()]) :: [struct()]
  def canonical(events) do
    dead = superseded_ids(events)

    Enum.reject(events, fn
      %PacketSuperseded{} -> true
      event -> superseded?(event, dead)
    end)
  end

  defp superseded?(event, dead) do
    case Map.get(event, :packet_id) do
      id when is_binary(id) -> MapSet.member?(dead, id)
      _ -> false
    end
  end

  @doc "The character a packet-bearing event belongs to (speaker or actor), or nil."
  @spec packet_character(struct()) :: term() | nil
  def packet_character(event) do
    cond do
      not is_nil(Map.get(event, :speaker_id)) -> Map.get(event, :speaker_id)
      not is_nil(Map.get(event, :character_id)) -> Map.get(event, :character_id)
      true -> nil
    end
  end

  @doc """
  The packets in `beat` as `{character_id, packet_id}` in cast (serial commit)
  order — one entry per packet, first appearance wins. `events` should already be
  `canonical/1` so superseded attempts don't appear.
  """
  @spec beat_packets([struct()], term()) :: [{term(), String.t()}]
  def beat_packets(events, beat) do
    events
    |> Enum.filter(fn e -> Map.get(e, :beat) == beat and is_binary(Map.get(e, :packet_id)) end)
    |> Enum.map(fn e -> {packet_character(e), Map.get(e, :packet_id)} end)
    |> Enum.reject(fn {char, _} -> is_nil(char) end)
    |> Enum.uniq()
  end

  @doc """
  The beat's cast from `character_id` to the end, as `{character_id, packet_id}`
  in serial order — the packets a re-roll or an invalidating edit of that turn
  makes stale (everything that conditioned on it). `{:error, :packet_not_found}`
  if the character has no packet in the beat. `events` should be `canonical/1`.
  """
  @spec beat_tail([struct()], term(), term()) ::
          {:ok, [{term(), String.t()}]} | {:error, :packet_not_found}
  def beat_tail(events, beat, character_id) do
    case Enum.split_while(beat_packets(events, beat), fn {char, _} -> char != character_id end) do
      {_head, []} -> {:error, :packet_not_found}
      {_head, tail} -> {:ok, tail}
    end
  end

  @doc "The highest beat with a canonical packet, or nil. `events` should be `canonical/1`."
  @spec latest_beat([struct()]) :: term() | nil
  def latest_beat(events) do
    beats = for e <- events, is_binary(Map.get(e, :packet_id)), do: Map.get(e, :beat)

    case beats do
      [] -> nil
      _ -> Enum.max(beats)
    end
  end
end
