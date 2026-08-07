defmodule Polyphony.Reading do
  @moduledoc """
  Where a reader got to in someone else's published campaign (§3.1e).

  A published campaign you're reading **isn't a campaign you own**. You can't play it,
  you may not be able to fork it, and its author can unpublish it out from under you.
  Filing it under Campaigns would promise all three; its own shelf promises exactly one
  thing — you can get back to where you were.

  ## The bookmark is scene, beat *and* perspective

  Perspective is part of where you were, not a preference you re-pick on arrival: a
  published campaign grants a set of reading perspectives (§3.1), and coming back into
  the wrong head is coming back to a different story. So all three travel together, and
  `resume/2` hands back all three.

  ## An unpublished campaign keeps its bookmark

  When the source goes away the shelf says so (`:gone`) and *keeps the row*, because
  unpublishing is frequently temporary and losing someone's place is not recoverable
  from the reader's side. Nothing here ever reaches into the author's live library —
  the bookmark points at the frozen published entry, which is the only thing a reader
  was ever shown.

  Stored as a library entry of kind `"bookmark"` owned by the **reader**, for the same
  reason `Polyphony.Groups` and `Polyphony.Campaigns` sit on the library: ownership,
  scoping and soft-delete are already solved there, and only what is specific to
  reading lives here.
  """

  alias PolyphonyCore.{MembershipSet, Packets, Publication, Visibility}
  alias Polyphony.App
  alias Polyphony.Library
  alias Polyphony.Library.Snapshot
  alias Polyphony.Owner
  alias Polyphony.Reading.Bookmark
  alias Polyphony.Reading.Session

  @kind "bookmark"

  @doc "The kind under which bookmarks are stored in the library."
  @spec kind() :: String.t()
  def kind, do: @kind

  @doc """
  Record (or move) a reader's place in a published campaign.

  Idempotent per `published_id`: a reader has one place in a story, so a second call
  moves the existing bookmark rather than stacking a second row. `attrs` are
  `Bookmark` fields — `:scene_id`, `:beat`, `:perspective`.

  Moving your place **un-finishes** the story: if you go back in, you're reading it
  again, and the shelf shouldn't keep insisting you're done.
  """
  @spec mark(term(), term(), map() | keyword(), keyword()) :: map()
  def mark(reader, published_id, attrs \\ %{}, opts \\ []) do
    attrs = Map.new(attrs)
    now = now(opts)

    fields =
      %{published_id: published_id, last_read_at: now, finished_at: nil}
      |> Map.merge(Map.take(attrs, [:scene_id, :beat, :perspective]))

    case entry_for(reader, published_id, opts) do
      nil ->
        Library.put(
          %{owner: reader, kind: @kind, payload: struct(Bookmark, fields)},
          opts
        )

      entry ->
        payload = entry |> Library.payload() |> Map.merge(fields)
        {:ok, updated} = Library.update_payload(entry.id, payload, opts)
        updated
    end
  end

  @doc "Where this reader was in `published_id`, or nil if they've never opened it."
  @spec bookmark(term(), term(), keyword()) :: Bookmark.t() | nil
  def bookmark(reader, published_id, opts \\ []) do
    case entry_for(reader, published_id, opts) do
      nil -> nil
      entry -> Library.payload(entry)
    end
  end

  @doc """
  The scene, beat and perspective to reopen at, as a plain tuple — nil if there's no
  bookmark. The reading screen's whole contract with this module.
  """
  @spec resume(term(), term(), keyword()) :: {term(), integer() | nil, term()} | nil
  def resume(reader, published_id, opts \\ []) do
    case bookmark(reader, published_id, opts) do
      nil -> nil
      %Bookmark{} = b -> {b.scene_id, b.beat, b.perspective}
    end
  end

  @doc """
  Say a reader reached the end. Distinct from `mark/4` at the last scene, because
  "finished it in March" is a different row from "partway through the last scene".
  """
  @spec finish(term(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def finish(reader, published_id, opts \\ []) do
    case entry_for(reader, published_id, opts) do
      nil ->
        {:error, :not_found}

      entry ->
        payload = entry |> Library.payload() |> Map.put(:finished_at, now(opts))
        Library.update_payload(entry.id, payload, opts)
    end
  end

  @doc "Take a story off the reading shelf. The reader's own choice — never automatic."
  @spec forget(term(), term(), keyword()) :: :ok
  def forget(reader, published_id, opts \\ []) do
    case entry_for(reader, published_id, opts) do
      nil ->
        :ok

      entry ->
        # Deliberately discarded. Taking something off your own shelf is idempotent —
        # the `nil` branch above already calls "it isn't there" success — so a row that
        # vanished between the lookup and the delete is the outcome asked for, not a
        # failure to report. The `with` this replaces leaked `{:error, :not_found}`
        # past a spec and a docstring that both promise `:ok`.
        _ = Library.soft_delete(entry.id, opts)
        :ok
    end
  end

  @doc """
  The reading shelf: one row per bookmark, most recently read first.

  Each row is `%{bookmark:, source:, state:}` where `state` is:

    * `:reading` — partway through, and the source is still there.
    * `:finished` — read to the end.
    * `:gone` — the author unpublished it (or it was deleted). The row **stays**, with
      the place kept, in case it comes back.
  """
  @spec shelf(term(), keyword()) :: [map()]
  def shelf(reader, opts \\ []) do
    reader
    |> Library.list_for_owner(opts)
    |> Enum.filter(&(&1.kind == @kind))
    |> Enum.map(fn entry ->
      bookmark = Library.payload(entry)
      source = source_of(bookmark, opts)

      %{
        id: entry.id,
        bookmark: bookmark,
        source: source,
        state: state(bookmark, source)
      }
    end)
    |> Enum.sort_by(& &1.bookmark.last_read_at, {:desc, NaiveDateTime})
  end

  @doc """
  How a row's place reads: `{index, count}` one-based, or nil when the source can't say.

  Only the published entry is consulted — never the author's live campaign — so an
  edit the reader was never shown can't shift their place under them.
  """
  @spec position(map(), map() | nil) :: {pos_integer(), pos_integer()} | nil
  def position(%Bookmark{scene_id: nil}, _source), do: nil
  def position(_bookmark, nil), do: nil

  def position(%Bookmark{scene_id: scene_id}, source) do
    Polyphony.Reading.Session.position(Library.payload(source) || %{}, scene_id)
  end

  @doc """
  The perspective badge: *As Halden* for a character, *All N* for omniscient.

  `names` maps character id to display name — `Polyphony.Scene.Cast`'s job everywhere
  else, and passed in here for the same reason: this module routes by id and never
  stores a name.
  """
  @spec perspective_label(map(), map()) :: String.t()
  def perspective_label(bookmark, names \\ %{})

  def perspective_label(%Bookmark{perspective: p}, _names)
      when p in [nil, :omniscient, "omniscient"],
      do: "Everything"

  # The reading modes share one vocabulary with the URL and with `Publication`, so the
  # label comes from there rather than from a second table that could disagree with it.
  def perspective_label(%Bookmark{perspective: p}, names) do
    PolyphonyCore.Publication.label(PolyphonyCore.Publication.from_param(p), nil, names)
  end

  # ── Internals ───────────────────────────────────────────────────────────────

  # A bookmark is `:gone` the moment the reader can no longer reach the source —
  # deleted, archived out of sight, or pulled back to private. Default-deny: anything
  # we can't positively confirm as readable reads as gone, which keeps a stale row
  # from offering a link into someone's unpublished draft.
  defp state(%Bookmark{finished_at: at}, source) when not is_nil(at) do
    if readable?(source), do: :finished, else: :gone
  end

  defp state(_bookmark, source), do: if(readable?(source), do: :reading, else: :gone)

  defp readable?(nil), do: false

  # Taken down counts as gone here, not as a shelf row that links to a dead end — the
  # row's own `:gone` copy is the honest answer (§B3).
  defp readable?(source),
    do:
      Library.live?(source) and source.visibility in ~w(public unlisted) and
        not Library.hidden?(source)

  defp source_of(%Bookmark{published_id: nil}, _opts), do: nil
  defp source_of(%Bookmark{published_id: id}, opts), do: Library.get(id, opts)

  defp entry_for(reader, published_id, opts) do
    want = to_string(published_id)

    reader
    |> Library.list_for_owner(opts)
    |> Enum.find(fn e ->
      e.kind == @kind and
        match?(%Bookmark{}, Library.payload(e)) and
        to_string(Library.payload(e).published_id) == want
    end)
  end

  defp now(opts), do: Keyword.get(opts, :now, NaiveDateTime.utc_now())

  # `Owner.coerce/1` is applied by `Library`; kept here so a caller can pass a user.
  @doc false
  def owner(reader), do: Owner.coerce(reader)

  @doc """
  The events of a published scene as `mode` may read them.

  Lived on `Reading.Session`, which is otherwise a pure projection over a snapshot the
  caller already holds — this was the one function in it that went to the event store,
  and it made the whole module read as a query. Here it sits with the rest of the
  reading side, which is where a read belongs.
  """
  @spec scene(Snapshot.t() | map(), term(), Publication.mode()) ::
          {:ok, [struct()]} | {:error, :not_offered}
  def scene(snapshot, scene_id, mode) do
    pub = Session.publication(snapshot)

    if Publication.offers?(pub, mode) do
      events = stored_events(scene_id)

      member_at? =
        events |> MembershipSet.from_events() |> MembershipSet.member_at_fun()

      {:ok, Visibility.project(events, Publication.viewer(pub, mode), member_at?)}
    else
      {:error, :not_offered}
    end
  end

  # The same canonical read every other fiction-facing read uses (rule 6): a re-rolled
  # or superseded take must never reappear, and a published story is the last place you
  # want one to.
  defp stored_events(scene_id) do
    App
    |> Commanded.EventStore.stream_forward(scene_id)
    |> Enum.map(& &1.data)
    |> Packets.canonical()
  rescue
    _ -> []
  end
end
