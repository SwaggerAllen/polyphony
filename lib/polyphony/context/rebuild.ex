defmodule Polyphony.Context.Rebuild do
  @moduledoc """
  Rebuild a cast member's frozen context from **durable** data when the ETS cache
  (`Context.Store`) misses — e.g. after a node restart wipes it mid-scene.

  The cache is pure and rebuildable (§6): a character's sheet lives in the campaign's
  Library entry, the premise/world on the scene's `SceneOpened` + campaign, and the
  long-tail in pgvector. Without this, `BeatOps.messages_for` fell back to a bare
  "You are X. Take your turn." prompt — no sheet, no scene, no schema — and the model,
  never having seen a TurnPacket, invented its own JSON shape (a `schema_invalid`
  failure on *every* autonomous beat after a restart).

  Best-effort: any missing piece yields `:error`, and the caller keeps its (now
  schema-bearing) fallback rather than failing the turn.
  """
  require Logger

  alias Polyphony.{App, Context, Library}
  alias Polyphony.Authoring.CharacterSheet
  alias Polyphony.Context.PgvectorRetriever
  alias Polyphony.Events.SceneOpened

  @doc "Rebuild `character_id`'s scene context from the log + library, or `:error`."
  @spec for_character(term(), term()) :: {:ok, Polyphony.Context.SceneContext.t()} | :error
  def for_character(scene_id, character_id) do
    with %SceneOpened{} = opened <- scene_opened(scene_id),
         %CharacterSheet{} = sheet <- sheet_for(opened.campaign_id, character_id) do
      ctx =
        Context.materialize(
          scene_id: scene_id,
          character_id: to_string(character_id),
          sheet: sheet,
          premise: opened.premise || "",
          world_bible: world_bible(opened.campaign_id),
          # Long-tail memory from pgvector (no-ops to [] without egress / on failure).
          retriever: PgvectorRetriever
        )

      {:ok, ctx}
    else
      _ -> :error
    end
  rescue
    e ->
      Logger.warning(
        "[context] rebuild failed for #{inspect(character_id)} in #{inspect(scene_id)}: " <>
          Exception.message(e)
      )

      :error
  end

  # The scene's opening event (campaign_id + premise) — the first event on the stream.
  defp scene_opened(scene_id) do
    case Commanded.EventStore.stream_forward(App, scene_id, 0, 8) do
      {:error, _} -> nil
      stream -> Enum.find_value(stream, fn e -> match?(%SceneOpened{}, e.data) && e.data end)
    end
  end

  # The campaign's authored cast, matched to the scene's character id by *name* (ids in
  # the scene are character names). Case-insensitive so "Lydia"/"lydia" resolve alike.
  defp sheet_for(nil, _character_id), do: nil

  defp sheet_for(campaign_id, character_id) do
    key = character_id |> to_string() |> String.downcase()

    with campaign when not is_nil(campaign) <- Library.get(campaign_id),
         %{} = payload <- Library.payload(campaign) do
      (payload[:character_ids] || payload["character_ids"] || [])
      |> Enum.map(&(&1 |> normalize_id() |> get_entry()))
      |> Enum.map(&entry_payload/1)
      |> Enum.find(fn
        %CharacterSheet{name: n} -> is_binary(n) and String.downcase(n) == key
        _ -> false
      end)
    else
      _ -> nil
    end
  end

  defp world_bible(nil), do: nil

  defp world_bible(campaign_id) do
    with campaign when not is_nil(campaign) <- Library.get(campaign_id),
         %{} = payload <- Library.payload(campaign),
         bid when not is_nil(bid) <- payload[:bible_id] || payload["bible_id"],
         entry when not is_nil(entry) <- get_entry(normalize_id(bid)) do
      Library.payload(entry)
    else
      _ -> nil
    end
  end

  defp get_entry(nil), do: nil
  defp get_entry(id), do: Library.get(id)

  defp entry_payload(nil), do: nil
  defp entry_payload(entry), do: Library.payload(entry)

  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp normalize_id(_), do: nil
end
