defmodule Polyphony.Drafts do
  @moduledoc """
  Pending turn drafts (§A2): the generate-then-confirm state between generation and
  commit, shared by two flows —

    * **assisted** control mode (§A1) — a cast member the user cares about is
      generated as a draft the user confirms, edits, or discards rather than
      committing straight to the log;
    * **suggestion** mode (FS V1 composer) — the same store holds the composer's
      candidate turns for the user's own character.

  A draft is workflow state, **not fiction**. It never touches the event log, so it
  can never reach any character's projection — the guarantee the brief protects. On
  **accept** it becomes a real `CommitPacket` (with `edited: true` if the user edited
  it); on **discard** nothing is committed. The `packet` round-trips losslessly as an
  Erlang term.
  """

  require Logger

  alias Polyphony.Blob
  alias Polyphony.Scene.Cast
  alias Polyphony.{App, Repo, Broadcast}
  alias Polyphony.ReadModels.PacketDraft
  alias Polyphony.Commands.CommitPacket
  alias Polyphony.Director.BeatOps

  @pubsub Polyphony.PubSub

  @doc "Store a generated `packet` as a pending draft and announce it. Returns the row."
  def draft(scene_id, character_id, beat, packet, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    row =
      PacketDraft.put(repo, %{
        scene_id: to_string(scene_id),
        character_id: to_string(character_id),
        beat: beat,
        source: to_string(Keyword.get(opts, :source, "assisted")),
        model: Keyword.get(opts, :model),
        status: "pending",
        edited: false,
        packet: encode(packet)
      })

    broadcast(row)
    row
  end

  @doc """
  The PubSub topic for a scene's draft workflow.

  Its own topic, deliberately **not** a viewer projection. A draft is workflow state
  that never touches the log, so it carries no fiction and no visibility decision —
  which is what lets a character view subscribe to it. Subscribing that view to the
  omniscient projection topic instead, to catch the same announcement, would hand it
  every other character's turns.
  """
  @spec topic(String.t()) :: String.t()
  def topic(scene_id), do: "scene:#{scene_id}:drafts"

  @doc "A draft row (packet still encoded — use `packet/1` to decode), or nil."
  def get(id, opts \\ []), do: PacketDraft.get(Keyword.get(opts, :repo, Repo), id)

  @doc "Pending drafts for a scene."
  def list_open(scene_id, opts \\ []),
    do: PacketDraft.list_open(Keyword.get(opts, :repo, Repo), scene_id)

  @doc "The decoded `TurnPacket` for a draft row."
  def packet(%PacketDraft{packet: bin}), do: decode(bin)

  @doc "Replace a draft's packet with an edited one (accept-and-edit); marks it edited."
  def edit(id, packet, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    case PacketDraft.get(repo, id) do
      nil -> {:error, :not_found}
      row -> {:ok, PacketDraft.update(repo, row, %{packet: encode(packet), edited: true})}
    end
  end

  @doc """
  Accept a pending draft: commit its packet to the scene (`edited: true` if it was
  edited), and mark the draft accepted. Returns `{:ok, %{scene_id, beat,
  character_id, packet_id}}`.
  """
  def accept(id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    case PacketDraft.get(repo, id) do
      nil ->
        {:error, :not_found}

      %PacketDraft{status: "pending"} = row ->
        packet_id = BeatOps.packet_id(row.scene_id, row.beat, row.character_id)

        :ok =
          App.dispatch(%CommitPacket{
            scene_id: row.scene_id,
            character_id: row.character_id,
            beat: row.beat,
            packet_id: packet_id,
            # The draft is stored as the model wrote it (names, so an author editing
            # it reads names); ids are minted here, on the way into the log.
            packet: Cast.resolve_addressees(row.scene_id, decode(row.packet)),
            edited: row.edited
          })

        PacketDraft.update(repo, row, %{status: "accepted"})

        {:ok,
         %{
           scene_id: row.scene_id,
           beat: row.beat,
           character_id: row.character_id,
           packet_id: packet_id
         }}

      _resolved ->
        {:error, :already_resolved}
    end
  end

  @doc "Discard a pending draft — nothing is committed."
  def discard(id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    case PacketDraft.get(repo, id) do
      nil -> {:error, :not_found}
      row -> {:ok, PacketDraft.update(repo, row, %{status: "discarded"})}
    end
  end

  # ── Codec ─────────────────────────────────────────────────────────────────

  # A packet is a term nobody queries (`:thought`, `:speech`, `TurnPacket`, …), so it is
  # stored whole — see `Polyphony.Blob`, which owns the `:safe` read.
  defp encode(packet), do: Blob.encode(packet)
  defp decode(bin), do: Blob.decode(bin)

  # ── Broadcast ─────────────────────────────────────────────────────────────

  defp broadcast(%PacketDraft{} = row) do
    announcement =
      {:polyphony_event,
       %{
         type: "draft.ready",
         viewer: "omniscient",
         draft_id: row.id,
         scene_id: row.scene_id,
         beat: row.beat,
         character_id: row.character_id,
         source: row.source
       }}

    Phoenix.PubSub.broadcast(@pubsub, Broadcast.topic(row.scene_id, :omniscient), announcement)
    # And on the workflow topic, so a screen looking through a character's eyes hears
    # about a draft awaiting them without subscribing to the omniscient projection —
    # which would hand it every other character's turns.
    Phoenix.PubSub.broadcast(@pubsub, topic(row.scene_id), announcement)

    :ok
  end
end
