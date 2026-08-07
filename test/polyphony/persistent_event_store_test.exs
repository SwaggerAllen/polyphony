defmodule Polyphony.PersistentEventStoreTest do
  @moduledoc """
  Proves the **production** event-store wiring end to end: commands dispatched
  through the persistent `Commanded.EventStore.Adapters.EventStore` adapter are
  persisted to Postgres and replay as the real event structs. The rest of the
  suite runs on the in-memory adapter (fast, SQL-sandbox isolated), so this is the
  one place `Polyphony.EventStore`, the prod serializer/schema config, and
  `Polyphony.Release.setup_event_store/0` are exercised against a real database —
  the drift the deploy smoke script can't catch in CI.

  `async: false` and outside the Ecto SQL sandbox: it provisions a dedicated
  `eventstore_test` schema in the test database and drops it afterwards.
  """
  use ExUnit.Case, async: false
  @moduletag :event_store

  alias Polyphony.PersistentApp
  alias PolyphonyCore.Commands.{OpenScene, EnterCharacter, CommitPacket}
  alias PolyphonyCore.Events.{SceneOpened, CharacterEntered, ThoughtOccurred, SpeechUttered}
  alias PolyphonyCore.TurnPacket
  alias PolyphonyCore.TurnPacket.{Move, SelfState}

  @schema "eventstore_test"

  setup_all do
    # The persistent-adapter config lives in config/test.exs; here we just bring
    # the store up (schema + tables via the real deploy path) and start the app.
    {:ok, _} = Application.ensure_all_started(:eventstore)
    :ok = Polyphony.Release.setup_event_store()

    start_supervised!(PersistentApp)

    # Just the Postgrex connection keys (the EventStore config also carries
    # serializer/schema/etc. which Postgrex doesn't take).
    es = Application.fetch_env!(:polyphony, Polyphony.EventStore)
    conn_opts = Keyword.take(es, [:username, :password, :hostname, :database, :port])

    on_exit(fn ->
      {:ok, conn} = Postgrex.start_link(conn_opts)
      Postgrex.query!(conn, ~s|DROP SCHEMA IF EXISTS "#{@schema}" CASCADE|, [])
      GenServer.stop(conn)
    end)

    %{conn_opts: conn_opts}
  end

  test "a dispatched scene is persisted to Postgres and replays as real events" do
    scene = "es-scene-" <> Integer.to_string(System.unique_integer([:positive]))

    :ok = PersistentApp.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})
    :ok = PersistentApp.dispatch(%EnterCharacter{scene_id: scene, character_id: "alice", beat: 1})
    :ok = PersistentApp.dispatch(%EnterCharacter{scene_id: scene, character_id: "bram", beat: 1})

    packet = %TurnPacket{
      moves: [
        %Move{seq: 1, type: :thought, content: "I can't let him know"},
        %Move{seq: 2, type: :speech, content: "Lovely evening, isn't it?"}
      ],
      self_state: %SelfState{mood_felt: "panicked", demeanor: "serene"}
    }

    :ok =
      PersistentApp.dispatch(%CommitPacket{
        scene_id: scene,
        character_id: "alice",
        beat: 2,
        packet_id: scene <> "-2-alice",
        packet: packet
      })

    # Read the stream back out of Postgres — deserialized through the configured
    # JSON serializer, so this exercises the full JSONB round-trip of real events.
    events =
      PersistentApp
      |> Commanded.EventStore.stream_forward(scene)
      |> Enum.map(& &1.data)

    assert [%SceneOpened{scene_id: ^scene} | rest] = events
    assert Enum.any?(rest, &match?(%CharacterEntered{character_id: "alice"}, &1))
    assert Enum.any?(rest, &match?(%ThoughtOccurred{content: "I can't let him know"}, &1))

    assert Enum.any?(
             rest,
             &match?(%SpeechUttered{content: "Lovely evening, isn't it?"}, &1)
           )
  end

  test "the events physically live in the dedicated eventstore schema", %{conn_opts: conn_opts} do
    scene = "es-scene-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = PersistentApp.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})

    # Short-lived connection, linked to this test process (dies with it).
    {:ok, conn} = Postgrex.start_link(conn_opts)

    # A row exists in <schema>.events (proving persistence, not in-memory).
    %{rows: [[n]]} =
      Postgrex.query!(conn, ~s|SELECT count(*) FROM "#{@schema}".events|, [])

    assert n >= 1
  end

  test "setup_event_store/0 is idempotent" do
    # Already run once in setup_all; a second run must be a no-op, not an error.
    assert :ok = Polyphony.Release.setup_event_store()
  end
end
