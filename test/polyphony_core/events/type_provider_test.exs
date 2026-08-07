defmodule PolyphonyCore.Events.TypeProviderTest do
  @moduledoc """
  What the event store already holds must still decode.

  The log is the single source of truth, and everything downstream of it — visibility,
  membership, the transcript — is a projection. So an event that no longer deserializes
  isn't a stale row; it is a hole in the story, and the failure mode is silent: the
  projection simply comes back shorter.

  The default type provider made that a rename away. `PolyphonyCore.Events.TypeProvider`
  fixes it going forward, but a fix you cannot see fail is a fix you will lose, so this
  pins three things nothing else can:

    * **The catalog is the vocabulary** — an event added without a stored name would
      otherwise fall back to its module name, quietly re-acquiring the original bug for
      exactly one event and nobody would notice until the next move.
    * **Every historical spelling still reads.** Driven off the catalog rather than a
      list, so it keeps covering events added later.
    * **Stored bytes still land in the right fields**, from a checked-in fixture that no
      test writes. `test/fixtures/stored_events.json` stands in for the database: it was
      generated once and is data from here on. Regenerating it to make this pass is
      exactly the move it exists to make visible.
  """
  use ExUnit.Case, async: true

  alias Commanded.Serialization.JsonSerializer
  alias PolyphonyCore.Events
  alias PolyphonyCore.Events.TypeProvider

  @fixture "test/fixtures/stored_events.json"

  defp catalog, do: TypeProvider.catalog()

  defp by_name, do: Map.new(catalog(), fn {module, name} -> {name, module} end)

  # Every module nested under `PolyphonyCore.Events` that is a struct — i.e. the event
  # vocabulary, discovered rather than restated.
  defp event_modules do
    prefix = "Elixir.PolyphonyCore.Events."

    :code.all_available()
    |> Enum.map(fn {mod, _, _} -> to_string(mod) end)
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.map(&String.to_existing_atom/1)
    |> Enum.filter(fn mod ->
      Code.ensure_loaded?(mod) and function_exported?(mod, :__struct__, 0)
    end)
    |> Enum.sort()
  end

  test "the catalog names every event, and only events" do
    named = catalog() |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    assert named == event_modules(), """
    The stored-name catalog and the event vocabulary disagree.

    Events with no stored name: #{inspect(event_modules() -- named)}
    Names for things that are not events: #{inspect(named -- event_modules())}

    An event missing from the catalog falls back to its module name, which is the bug
    `PolyphonyCore.Events.TypeProvider` exists to end — add a stable `snake_case.v1` name.
    """
  end

  test "no two events share a stored name" do
    names = Enum.map(catalog(), &elem(&1, 1))
    assert names == Enum.uniq(names)
  end

  test "an event writes its stable name, not its module path" do
    for {module, name} <- catalog() do
      assert TypeProvider.to_string(struct(module)) == name
      refute name =~ "Elixir.", "#{name} still names a module — the point is that it can't"
    end
  end

  test "every spelling the vocabulary has ever been stored under still reads" do
    for {module, name} <- catalog() do
      short = module |> Module.split() |> List.last()

      spellings = [name | Enum.map(TypeProvider.legacy_namespaces(), &(&1 <> short))]

      for spelling <- spellings do
        assert TypeProvider.to_struct(spelling) == struct(module),
               "#{spelling} no longer decodes to #{inspect(module)}"
      end
    end
  end

  test "a struct that is not an event falls back to its module name" do
    # Snapshots and process-manager state go through the same provider. This app uses
    # neither, and a provider that raised would make enabling one fail somewhere strange.
    assert TypeProvider.to_string(%Polyphony.TurnPacket{}) == "Elixir.Polyphony.TurnPacket"
    assert TypeProvider.to_struct("Elixir.Polyphony.TurnPacket") == %Polyphony.TurnPacket{}
  end

  describe "stored bytes" do
    setup do
      {:ok, stored: @fixture |> File.read!() |> Jason.decode!(), modules: by_name()}
    end

    test "the fixture covers the whole catalog", %{stored: stored} do
      covered = stored |> Enum.map(& &1["event"]) |> Enum.sort()
      expected = catalog() |> Enum.map(&elem(&1, 1)) |> Enum.sort()

      assert covered == expected, """
      #{@fixture} and the catalog disagree.

      Uncovered events: #{inspect(expected -- covered)}
      Fixtures for nothing: #{inspect(covered -- expected)}
      """
    end

    test "every field on every event survives the round trip", %{stored: stored, modules: mods} do
      for %{"event" => name, "data" => data} <- stored do
        module = Map.fetch!(mods, name)
        decoded = JsonSerializer.deserialize(data, type: name)

        assert decoded.__struct__ == module

        # The fixture populates every field, so a `nil` here means a stored key no longer
        # names a field on the struct — which is what a field rename looks like from the
        # store's side, and it is otherwise completely silent.
        empty =
          decoded
          |> Map.from_struct()
          |> Enum.filter(fn {_k, v} -> is_nil(v) end)
          |> Enum.map(&elem(&1, 0))

        assert empty == [], "#{name} decoded with #{inspect(empty)} unset — renamed fields?"
      end
    end

    test "a whisper read from the fixture is still a whisper", %{stored: stored} do
      speech = Enum.find(stored, &(&1["event"] == "speech_uttered.v1"))

      decoded = JsonSerializer.deserialize(speech["data"], type: "speech_uttered.v1")

      # Not a field check — a guarantee check. JSON has no atoms, so without the
      # `JsonDecoder` impl this arrives as `"private"`, misses `Visibility`'s `:private`
      # clause, and the whisper is audible to everyone in the scene.
      assert %Events.SpeechUttered{audibility: :private, addressed_to: ["char-ilias"]} = decoded
    end

    test "the legacy spellings decode the same bytes the same way", %{stored: stored} do
      for %{"event" => name, "data" => data} <- stored do
        module = Map.fetch!(by_name(), name)
        short = module |> Module.split() |> List.last()
        expected = JsonSerializer.deserialize(data, type: name)

        for namespace <- TypeProvider.legacy_namespaces() do
          assert JsonSerializer.deserialize(data, type: namespace <> short) == expected
        end
      end
    end
  end
end
