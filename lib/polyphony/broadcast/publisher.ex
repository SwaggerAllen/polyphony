defmodule Polyphony.Broadcast.Publisher do
  @moduledoc """
  The live tail (§13): a Commanded event handler that publishes each committed
  scene event to its per-viewer `Phoenix.PubSub` topics, filtered by
  `Polyphony.Broadcast.fan_out/5`.

  It derives membership and the scene roster from the event stream itself (like
  the beat runner), so it needs **no Postgres** — which also means it is safe to
  run in tests without the Ecto sandbox. `start_from: :current` so it tails new
  events rather than replaying history on boot; reconnecting clients get history
  via `Broadcast.replay/4` instead.
  """
  use Commanded.Event.Handler,
    application: Polyphony.App,
    name: "broadcast_publisher",
    start_from: :current

  alias Polyphony.{App, Broadcast}
  alias PolyphonyCore.{MembershipSet, Packets}

  @pubsub Polyphony.PubSub

  @impl Commanded.Event.Handler
  def handle(event, metadata) do
    case Broadcast.scene_id_of(event) do
      nil -> :ok
      scene_id -> publish(scene_id, event, seq(metadata))
    end
  end

  defp publish(scene_id, event, seq) do
    events = stored_events(scene_id)
    member_at? = events |> MembershipSet.from_events() |> MembershipSet.member_at_fun()
    roster = roster(events)

    scene_id
    |> Broadcast.fan_out(event, seq, roster, member_at?)
    |> Enum.each(fn {topic, message} ->
      Phoenix.PubSub.broadcast(@pubsub, topic, {:polyphony_event, message})
    end)

    :ok
  end

  defp roster(events) do
    events |> Enum.flat_map(&Broadcast.character_ids/1) |> Enum.uniq()
  end

  defp stored_events(scene_id) do
    App
    |> Commanded.EventStore.stream_forward(scene_id)
    |> Enum.map(& &1.data)
    |> Packets.canonical()
  rescue
    _ -> []
  end

  # Per-scene cursor: position within the scene stream.
  defp seq(%{stream_version: v}) when is_integer(v), do: v
  defp seq(%{event_number: n}), do: n
  defp seq(_), do: nil
end
