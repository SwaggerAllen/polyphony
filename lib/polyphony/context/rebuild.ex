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

  Best-effort is not the same as silent, and the difference cost something real. Every
  read here ends in a `rescue` that returns a benign default, and one of them —
  `content_config/1` — hands back the **all-off** content ceiling. When a namespace move
  made stored payloads undecodable (see `PolyphonyCore.Blob`), that `rescue` turned a
  broken read into an §A5 setting quietly reverting to its default: nothing failed, the
  ceiling just dropped. So every fallback says so at warning level, through `degraded/2`.
  The return values are unchanged — the caller still gets to carry on. `degraded/2` only
  logs and hands the default back to its own `rescue` rather than returning it, because
  routing six exact return types through one helper collapses them into their union and
  Dialyzer is right to object.
  """
  require Logger

  alias Polyphony.{App, Context, Library}
  alias Polyphony.Authoring.CharacterSheet
  alias Polyphony.Authoring.Effective
  alias PolyphonyCore.Content.CampaignConfig
  alias Polyphony.Context.PgvectorRetriever
  alias Polyphony.Scene.Cast
  alias PolyphonyCore.Events.{CharacterEntered, SceneOpened}

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
         %CharacterSheet{} = sheet <- sheet_for(scene_id, character_id) do
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
          # Other people's secrets this character is let in on (§3.3). Resolved here
          # rather than stored, so a group's membership moving moves the audience.
          cast: cast(scene_id),
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
    e ->
      degraded(e, "opened/#{inspect(scene_id)}")
      nil
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
    e ->
      degraded(e, "roster/#{inspect(scene_id)}")
      []
  end

  @doc """
  The campaign's cast as `[{character_id, sheet}]` — what a context needs to work out
  whose secrets this character starts out in on (§3.3).

  Keyed by the same library id everything else routes by, and **authored** sheets
  rather than effective ones: an audience is authored, arc never adds one, and the
  alternative is a canon-arc read per cast member on every scene open.
  """
  @spec cast(term()) :: [{String.t(), CharacterSheet.t()}]
  def cast(scene_id) do
    with %SceneOpened{campaign_id: cid} when not is_nil(cid) <- opened(scene_id),
         campaign when not is_nil(campaign) <- Library.get(cid),
         %{} = payload <- Library.payload(campaign) do
      for raw <- payload[:character_ids] || payload["character_ids"] || [],
          id = normalize_id(raw),
          entry = get_entry(id),
          %CharacterSheet{} = sheet <- [entry_payload(entry)] do
        {to_string(entry.id), sheet}
      end
    else
      _ -> []
    end
  rescue
    e ->
      degraded(e, "cast/#{inspect(scene_id)}")
      []
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
    # The loudest of these: the fallback is the all-off ceiling, which looks exactly like
    # an author who turned everything off.
    e ->
      degraded(e, "content_config/#{inspect(scene_id)}")
      %CampaignConfig{}
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
    e ->
      degraded(e, "world_bible/#{inspect(scene_id)}")
      nil
  end

  @doc """
  Resolve a scene's `character_id` to its sheet (§5.2 identity migration): by **library
  id first** — so a stable id survives a display-name change (rename-safe) — then the
  legacy **name** match, since character ids minted before the migration are names. Both
  paths are safe: a name never parses as a library id, so it can't mis-resolve. Returns
  `nil` when nothing matches.
  """
  @spec sheet_for(term(), term()) :: CharacterSheet.t() | nil
  def sheet_for(scene_id, character_id) do
    sheet_by_id(character_id) || find_sheet(roster(scene_id), character_id)
  end

  defp sheet_by_id(character_id) do
    with id when not is_nil(id) <- as_library_id(character_id),
         entry when not is_nil(entry) <- get_entry(id),
         %CharacterSheet{} = sheet <- entry_payload(entry) do
      sheet
    else
      _ -> nil
    end
  end

  # A character_id is a library id only if it's an integer or an all-digit string — a
  # display name (the legacy key) never is, so this never mis-resolves a name.
  defp as_library_id(id) when is_integer(id), do: id

  defp as_library_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp as_library_id(_), do: nil

  # Match a scene character id (a legacy *name*) to its sheet in the roster, case-insensitively.
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

  @doc """
  The scene's cast, built from the characters that have entered it.

  Was `Scene.Cast.for_scene/1`, and it is the read that made `Cast` look like a query
  module — everything else on that struct maps ids to names and back, from data the
  caller already has. It belongs here, beside `sheet_for/2`, which it calls for every id
  it finds.

  Callers that used to hand a `scene_id` straight to `Cast.resolve_addressees/2` now
  compose the two, which is the point: the read is visible at the call site instead of
  hiding inside something that reads as pure.
  """
  @spec cast_for(term()) :: Cast.t()
  def cast_for(scene_id) do
    sheets =
      for id <- entered_ids(scene_id),
          %CharacterSheet{name: n} = sheet <- [sheet_for(scene_id, id)],
          is_binary(n) and n != "",
          do: {to_string(id), sheet}

    pairs = for {id, sheet} <- sheets, do: {id, sheet.name}

    %Cast{
      id_to_name: Map.new(pairs),
      name_to_id: Map.new(pairs, fn {id, name} -> {name, id} end),
      # The voice colour is stored on the sheet, so it comes along with the name —
      # same read, and a rename or a cast change can't move it.
      id_to_hue: Map.new(sheets, fn {id, sheet} -> {id, sheet.hue} end)
    }
  end

  defp entered_ids(scene_id) do
    scene_id
    |> stored_events()
    |> Enum.flat_map(fn
      %CharacterEntered{character_id: id} -> [to_string(id)]
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp stored_events(scene_id) do
    # A scene with no stream yet is ordinary, not a degradation — matched the way
    # `opened/1` matches it, so the rescue below is left holding only real surprises.
    case Commanded.EventStore.stream_forward(App, scene_id) do
      {:error, _} -> []
      stream -> Enum.map(stream, & &1.data)
    end
  rescue
    e ->
      degraded(e, "stored_events/#{inspect(scene_id)}")
      []
  end

  # A read that failed and is carrying on anyway. Says so and returns nothing — the
  # default belongs to the caller, and routing it through here collapsed six exact return
  # types into their union.
  defp degraded(exception, where),
    do:
      Logger.warning(
        "[context] #{where} fell back to a default: " <> Exception.message(exception)
      )
end
