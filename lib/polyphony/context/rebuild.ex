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
  alias Polyphony.Authoring.Effective
  alias Polyphony.Content.CampaignConfig
  alias Polyphony.Context.PgvectorRetriever
  alias Polyphony.Events.SceneOpened

  @doc """
  The retriever a cold-cache rebuild (character or Director) pulls long-tail memory
  with. Defaults to pgvector (matching scene-open); env-swappable — like `:embedder` —
  so tests can use the DB-free static retriever without hitting the sandbox off-process.
  """
  def retriever, do: Application.get_env(:polyphony, :rebuild_retriever, PgvectorRetriever)

  @doc "Rebuild `character_id`'s scene context from the log + library, or `:error`."
  @spec for_character(term(), term()) :: {:ok, Polyphony.Context.SceneContext.t()} | :error
  def for_character(scene_id, character_id) do
    with %SceneOpened{} = opened <- opened(scene_id),
         %CharacterSheet{} = sheet <- find_sheet(roster(scene_id), character_id) do
      ctx =
        Context.materialize(
          scene_id: scene_id,
          character_id: to_string(character_id),
          # Canon character + world arc folded in (§2.8) so accepted arc reaches
          # generation; world facts scoped to this scene's location (global + local-here).
          sheet: Effective.sheet(sheet, character_id),
          premise: opened.premise || "",
          location: opened.location_id,
          world_bible:
            Effective.world_bible(world_bible(scene_id), opened.campaign_id, opened.location_id),
          # Re-apply the campaign content ceiling (§A5) so a rebuilt context caps the
          # same boundaries as the original seed — a cache wipe must not re-open them.
          content_config: content_config(scene_id),
          # Long-tail memory (pgvector by default; no-ops to [] without egress / on failure).
          retriever: retriever()
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

  @doc "The scene's opening event (campaign_id + premise), or nil. The first on the stream."
  @spec opened(term()) :: SceneOpened.t() | nil
  def opened(scene_id) do
    case Commanded.EventStore.stream_forward(App, scene_id, 0, 8) do
      {:error, _} -> nil
      stream -> Enum.find_value(stream, fn e -> match?(%SceneOpened{}, e.data) && e.data end)
    end
  rescue
    _ -> nil
  end

  @doc """
  The scene's campaign cast as authored sheets (the durable source of the frozen
  context both the cast and the Director condition on). Empty when there's no campaign.
  """
  @spec roster(term()) :: [CharacterSheet.t()]
  def roster(scene_id) do
    with %SceneOpened{campaign_id: cid} when not is_nil(cid) <- opened(scene_id),
         campaign when not is_nil(campaign) <- Library.get(cid),
         %{} = payload <- Library.payload(campaign) do
      (payload[:character_ids] || payload["character_ids"] || [])
      |> Enum.map(&(&1 |> normalize_id() |> get_entry()))
      |> Enum.map(&entry_payload/1)
      |> Enum.filter(&match?(%CharacterSheet{}, &1))
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  @doc "The scene's campaign content config (§A5), or the all-off default."
  @spec content_config(term()) :: CampaignConfig.t()
  def content_config(scene_id) do
    with %SceneOpened{campaign_id: cid} when not is_nil(cid) <- opened(scene_id),
         campaign when not is_nil(campaign) <- Library.get(cid),
         %{} = payload <- Library.payload(campaign) do
      CampaignConfig.from_payload(payload)
    else
      _ -> %CampaignConfig{}
    end
  rescue
    _ -> %CampaignConfig{}
  end

  @doc "The scene's campaign world bible (`%WorldBible{}`), or nil."
  @spec world_bible(term()) :: term() | nil
  def world_bible(scene_id) do
    with %SceneOpened{campaign_id: cid} when not is_nil(cid) <- opened(scene_id),
         campaign when not is_nil(campaign) <- Library.get(cid),
         %{} = payload <- Library.payload(campaign),
         bid when not is_nil(bid) <- payload[:bible_id] || payload["bible_id"],
         entry when not is_nil(entry) <- get_entry(normalize_id(bid)) do
      Library.payload(entry)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Match a scene character id (a *name*) to its sheet in the roster, case-insensitively.
  defp find_sheet(roster, character_id) do
    key = character_id |> to_string() |> String.downcase()

    Enum.find(roster, fn
      %CharacterSheet{name: n} -> is_binary(n) and String.downcase(n) == key
      _ -> false
    end)
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
