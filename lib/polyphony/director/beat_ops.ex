defmodule Polyphony.Director.BeatOps do
  @moduledoc """
  Shared, mostly-pure helpers for driving a beat — used by the Oban jobs
  (`RunBeat`, `GeneratePacket`) so the beat loop's plumbing lives in one place.

  Deterministic ids (`beat_ref/2`, `packet_id/3`), membership read from the
  stream, per-character message assembly from the cached context, and the two
  side-effecting plan applications (world events, membership changes) that run
  before the cast generates.
  """

  alias Polyphony.{App, Context, MembershipSet}
  alias Polyphony.Context.Store
  alias Polyphony.Commands.{RecordWorldEvent, ExitCharacter, CloseScene}
  alias Polyphony.Director.Proposal

  @doc "The beat aggregate's stream id (distinct from the integer scene beat)."
  def beat_ref(scene_id, beat), do: "#{scene_id}-b#{beat}"

  @doc "Deterministic packet id `(scene, beat, character)` for idempotency (§12)."
  def packet_id(scene_id, beat, character_id), do: "#{scene_id}-#{beat}-#{character_id}"

  @doc "All events on a scene's stream (empty if the stream doesn't exist yet)."
  def stored_events(scene_id) do
    App |> Commanded.EventStore.stream_forward(scene_id) |> Enum.map(& &1.data)
  rescue
    _ -> []
  end

  @doc "Character ids present in the scene at `beat`, derived from the log."
  def members_now(scene_id, beat) do
    scene_id
    |> stored_events()
    |> MembershipSet.from_events()
    |> MembershipSet.members_at(scene_id, beat)
  end

  @doc """
  Build a cast member's messages: the cached frozen prefix plus the freshly
  re-read live history (so serial conditioning holds), plus any pacing note.
  Falls back to a minimal seed if no context is cached.
  """
  def messages_for(scene_id, beat, character_id, pacing_note \\ nil) do
    live = stored_events(scene_id)
    members = members_now(scene_id, beat)

    base =
      case Store.fetch(scene_id, character_id) do
        {:ok, ctx} ->
          Context.to_messages(ctx, live_events: live, members: members)

        :error ->
          [
            %{role: "system", content: "You are #{character_id}."},
            %{
              role: "user",
              content: "It is your turn. Respond with a valid TurnPacket JSON object."
            }
          ]
      end

    base ++ pacing(pacing_note)
  end

  defp pacing(note) when is_binary(note) and note != "",
    do: [%{role: "user", content: "Direction: #{note}"}]

  defp pacing(_), do: []

  @doc "Dispatch the Director's authored world events onto the scene log."
  def author_world_events(world_events, scene_id, beat) do
    Enum.each(world_events, fn we ->
      App.dispatch(%RecordWorldEvent{
        scene_id: Map.get(we, :scene_id) || scene_id,
        beat: beat,
        content: we.content
      })
    end)
  end

  @doc """
  Apply membership-changing parts of the plan (accepted exits, close/move scene
  actions). Returns `:changed` or `:unchanged` — `:changed` triggers beat
  truncation (§10).
  """
  def apply_membership_changes(resolved, scene_id, beat) do
    exits = Enum.filter(resolved.accepted, &match?(%Proposal{type: :exit}, &1))
    closes = Enum.filter(resolved.scene_actions, &(&1.action in [:close, :move]))

    Enum.each(exits, fn %Proposal{actor_id: who} ->
      App.dispatch(%ExitCharacter{scene_id: scene_id, character_id: who, beat: beat})
    end)

    Enum.each(closes, fn
      %{action: :close} ->
        App.dispatch(%CloseScene{scene_id: scene_id, closed_beat: beat})

      %{action: :move, character_id: who} ->
        App.dispatch(%ExitCharacter{scene_id: scene_id, character_id: who, beat: beat})
    end)

    if exits == [] and closes == [], do: :unchanged, else: :changed
  end

  @doc "Resolve an optional `\"provider\"` arg (module name string) to a module."
  def resolve_provider(nil), do: nil
  def resolve_provider(mod) when is_atom(mod), do: mod

  def resolve_provider(str) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> nil
  end
end
