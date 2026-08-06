defmodule Polyphony.Campaigns do
  @moduledoc """
  Campaigns as library entries: their lifecycle, and the reads the library's rows need
  (`ux/polyphony-library.html`).

  Sits beside `Polyphony.Characters` and `Polyphony.Groups` for the same reason —
  storage, ownership, archiving and versioning are `Polyphony.Library`'s job, and only
  what is specific to campaigns lives here.

  ## Finishing is not archiving (§2.5c)

  Two different things, deliberately kept apart:

    * **Archived** — filing. Out of the default lists, reversible, and carrying no
      meaning about the story. `Library.archive/2`.
    * **Finished** — a statement. The campaign is a concluded whole. It is the
      precondition for another campaign naming it as a prequel (§3.4), and it is
      reversible, because concluding something is a judgement and judgements change.

  A campaign nobody has opened yet is neither: it is `:unstarted`, which the library
  says out loud rather than showing an empty row that looks broken.

  ## Status is derived where it can be

  `:playing` versus `:unstarted` is a fact about the scenes list, not a flag somebody
  has to remember to set — so it is read, never stored. Only `finished_at` is stored,
  because "this story is over" is the one thing the data cannot work out for itself.
  """

  alias Polyphony.Authoring.CharacterSheet
  alias Polyphony.Library
  alias Polyphony.ReadModels.LibraryEntry
  alias Polyphony.ReadModels.ArcEntry
  alias Polyphony.Repo

  @kind "campaign"

  @type status :: :unstarted | :playing | :finished

  @doc "The kind under which campaigns are stored in the library."
  @spec kind() :: String.t()
  def kind, do: @kind

  @doc """
  Every campaign owned by `owner`, newest first (the library's own order).

  **Published snapshots are excluded.** They share the `"campaign"` kind because they
  share a table, and nothing else: a snapshot can't be played, finished, cast or
  reviewed, and its payload is a `Library.Snapshot` with none of a campaign's fields.
  Handing one to anything in this module used to raise — `Snapshot` is a struct, so
  `payload[:scenes]` has no `Access` to go through — which meant publishing anything
  took the library down.
  """
  @spec list(term(), keyword()) :: [map()]
  def list(owner, opts \\ []) do
    owner
    |> Library.list_for_owner(opts)
    |> Enum.filter(&campaign?/1)
  end

  @doc """
  Is this library entry a campaign somebody is working on, rather than a frozen copy
  of one? The one place the distinction is made, so callers stop inferring it from
  `kind`.
  """
  @spec campaign?(map()) :: boolean()
  def campaign?(%{kind: @kind} = entry), do: not Library.snapshot?(entry)
  def campaign?(_entry), do: false

  @doc """
  Where a campaign is in its life.

    * `:unstarted` — made and never opened. No scenes.
    * `:playing` — scenes have happened and it hasn't been concluded.
    * `:finished` — deliberately concluded (§2.5c).

  Derived from the payload rather than stored, apart from the one bit that can't be.
  """
  @spec status(map() | nil) :: status()
  def status(nil), do: :unstarted

  # `Map.get/2` rather than `payload[...]`: the latter needs `Access`, which a struct
  # doesn't implement, so a payload of an unexpected shape raised instead of answering.
  # Defence in depth — `list/2` already keeps snapshots out — but a lifecycle read is
  # exactly the kind of thing that gets called from somewhere new.
  def status(payload) do
    cond do
      Map.get(payload, :finished_at) -> :finished
      (Map.get(payload, :scenes) || []) != [] -> :playing
      true -> :unstarted
    end
  end

  @doc "How a status reads on a library row."
  @spec status_label(status()) :: String.t()
  def status_label(:playing), do: "Playing"
  def status_label(:finished), do: "Finished"
  def status_label(_), do: "Not started"

  @doc """
  Conclude a campaign — a statement, not filing.

  Deliberately does **not** archive: a finished campaign is the one you most want to be
  able to find, to read back or to name as a prequel. Closing any open scene is the
  caller's job through the normal path, because a scene closing is an event and this is
  a library write.
  """
  @spec finish(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def finish(id, opts \\ []), do: stamp_finished(id, now(opts), opts)

  @doc "Un-conclude it. Reversible, because concluding something is a judgement."
  @spec reopen(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def reopen(id, opts \\ []), do: stamp_finished(id, nil, opts)

  defp stamp_finished(id, value, opts) do
    case Library.get(id, opts) do
      nil ->
        {:error, :not_found}

      entry ->
        payload = entry |> Library.payload() |> Map.put(:finished_at, value)
        Library.update_payload(id, payload, opts)
    end
  end

  defp now(opts), do: Keyword.get(opts, :now, NaiveDateTime.utc_now())

  # Everything derived from a scene stream, keyed by the scene it came from. The same
  # set `Polyphony.SceneReset` truncates globally — minus `projection_versions`, which
  # is Commanded's own projector bookkeeping and is not per-campaign: clearing it here
  # would rewind every projector for every campaign to replay this one.
  @scene_derived [
    {"scene_memberships", "scene_id"},
    {"character_scene_summaries", "scene_id"},
    {"arc_entries", "source_scene_id"},
    {"generation_failures", "scene_id"},
    {"packet_drafts", "scene_id"},
    {"scene_forks", "scene_id"}
  ]

  @doc """
  Put a campaign back to before it was played, keeping everything that was written.

  The cast, the world and the premise are authored work and survive untouched; the
  scenes and everything derived from them go. That includes the **arc queue** — the
  proposals play raised about these characters — which is the reason this exists as
  its own control rather than as "delete the scenes": an arc entry outliving the scene
  that proposed it is a review item about something that never happened.

  It does **not** delete the event streams, and cannot: events are immutable (rule 6),
  and rewriting or dropping history is the one thing an event-sourced system may never
  do. What it does is stop the campaign referring to them — the streams are abandoned,
  not erased, and nothing reads a stream that no campaign names. `SceneReset` is the
  global version and only *it* is entitled to touch the store, because it is a
  deployment-level clean slate rather than one author's decision about one story.

  A finished campaign restarts as unstarted: concluding it was a statement about a
  story that is now being started again.

  Returns `{:ok, %{scenes: n, rows: %{table => n}}}` — what was actually let go of.
  """
  @spec restart(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def restart(id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    case Library.get(id, opts) do
      nil ->
        {:error, :not_found}

      entry ->
        payload = Library.payload(entry)
        scenes = List.wrap(Map.get(payload, :scenes))

        rows =
          for {table, column} <- @scene_derived, into: %{} do
            {table, delete_by_scene(repo, table, column, scenes)}
          end

        {:ok, _} =
          Library.update_payload(
            id,
            payload |> Map.put(:scenes, []) |> Map.put(:finished_at, nil),
            opts
          )

        {:ok, %{scenes: length(scenes), rows: rows}}
    end
  end

  defp delete_by_scene(_repo, _table, _column, []), do: 0

  defp delete_by_scene(repo, table, column, scenes) do
    %{num_rows: n} =
      repo.query!(~s|DELETE FROM "#{table}" WHERE "#{column}" = ANY($1)|, [scenes])

    n
  end

  @doc """
  How many arc proposals are waiting on this campaign — its cast's plus its world's.

  What the library row's *3 to review* counts, and the same thing the scene gate will
  block on, so the number an author sees before opening a campaign is the number that
  will stop them.
  """
  @spec pending_review(map(), keyword()) :: non_neg_integer()
  def pending_review(entry, opts \\ [])

  # Nothing is ever waiting on a frozen copy: it has no cast to propose about and no
  # next scene to gate.
  def pending_review(%{frozen: true}, _opts), do: 0

  def pending_review(entry, opts) do
    repo = Keyword.get(opts, :repo, Repo)
    payload = Library.payload(entry) || %{}

    # Counted off one flat list rather than summing per-character lengths: `Enum.sum/1`
    # is spec'd `:: number()` upstream, so a count of proposals reads as possibly-float,
    # while `length/1` is provably a non-negative integer.
    cast_count =
      (Map.get(payload, :character_ids) || [])
      |> Enum.uniq()
      |> Enum.flat_map(&ArcEntry.list_proposed(repo, &1))
      |> length()

    cast_count + length(ArcEntry.list_proposed_world(repo, entry.id))
  end

  @doc """
  The campaign each of `owner`'s characters belongs to, as `%{character_id => entry}`.

  Characters don't cross campaigns (§2.7), so every one belongs to exactly **one** —
  which is what makes the library's grouping free rather than a judgement call, and
  what keeps the list navigable at forty walk-ons. A character in no campaign yet maps
  to nothing and the caller decides where to put them.
  """
  @spec by_character(term(), keyword()) :: %{String.t() => map()}
  def by_character(owner, opts \\ []) do
    for campaign <- list(owner, opts),
        payload = Library.payload(campaign) || %{},
        id <- Map.get(payload, :character_ids) || [],
        into: %{},
        do: {to_string(id), campaign}
  end

  @doc """
  Put a character on a campaign's roster. Idempotent; a nil campaign or character is a
  no-op.

  Everything that invents a person invents them *for a story*, and until this existed
  each path had to remember to say so — so none of them did. A stub written from a
  relationship, a walk-on Quick Build's cast introduced, a name the Director mentioned
  mid-scene: all landed in the library owned by nobody's campaign, which meant
  `by_character/2` filed them under "Not in a campaign", the cast tab's *fill them in*
  prompt could never see them, and §2.7's "characters do not cross campaigns" described
  a rule about people who belonged to none.

  Tier is what keeps the roster readable (§2.5) — a walk-on collapses behind a count —
  so joining it costs nothing and being absent from it costs the screens above.
  """
  @spec cast(term() | nil, term() | nil, keyword()) :: :ok
  def cast(campaign, character_id, opts \\ [])
  def cast(nil, _character_id, _opts), do: :ok
  def cast(_campaign, nil, _opts), do: :ok

  # An entry or an id, because `by_character/2` and `of_character/3` hand back entries
  # while the build job has only an id. Matching the struct explicitly rather than
  # letting it fall through to `Library.get/2`, which answers nil for one and would turn
  # a wrong argument into a silent no-op.
  def cast(%LibraryEntry{} = campaign, character_id, opts),
    do: cast(campaign.id, character_id, opts)

  def cast(campaign_id, character_id, opts) do
    case Library.get(campaign_id, opts) do
      nil ->
        :ok

      entry ->
        payload = Library.payload(entry) || %{}
        ids = Map.get(payload, :character_ids) || []

        if character_id in ids do
          :ok
        else
          Library.update_payload(
            entry.id,
            Map.put(payload, :character_ids, ids ++ [character_id]),
            opts
          )

          :ok
        end
    end
  end

  @doc """
  Take a character off a campaign's roster, and **cut the ties both ways**.

  Removing somebody used to drop an id from a list and leave every sentence about them
  where it was: the cast still regarded them, their sheet still regarded the cast, and
  every one of those `target_id`s now pointed at a person no longer in the story. It
  reads as a bug on the remaining sheets, and it feeds the prompt — `Context` renders
  relationships, so the character who left keeps being described to people who can no
  longer meet them.

  **Both directions**, because a relationship is a link between two people who share a
  story and neither half survives one of them leaving. Ties to characters *outside* this
  campaign are untouched: they were never this campaign's to sever.

  Matching by id and, for the ones written before ids were resolved, by name — a
  legacy name-only link is exactly the kind that would otherwise be left dangling and
  invisible.
  """
  @spec uncast(term() | nil, term() | nil, keyword()) :: :ok
  def uncast(campaign, character_id, opts \\ [])
  def uncast(nil, _character_id, _opts), do: :ok
  def uncast(_campaign, nil, _opts), do: :ok

  def uncast(%LibraryEntry{} = campaign, character_id, opts),
    do: uncast(campaign.id, character_id, opts)

  def uncast(campaign_id, character_id, opts) do
    case Library.get(campaign_id, opts) do
      nil ->
        :ok

      entry ->
        payload = Library.payload(entry) || %{}
        ids = Map.get(payload, :character_ids) || []
        remaining = Enum.reject(ids, &same_ref?(&1, character_id))

        Library.update_payload(entry.id, Map.put(payload, :character_ids, remaining), opts)
        sever(character_id, remaining, opts)
        :ok
    end
  end

  # The leaver forgets the cast, and the cast forgets the leaver.
  defp sever(left_id, remaining, opts) do
    leaver = Library.get(left_id, opts)
    left_names = names_of([leaver])
    remaining_entries = remaining |> Enum.map(&Library.get(&1, opts)) |> Enum.reject(&is_nil/1)

    Enum.each(remaining_entries, &drop_links(&1, [left_id], left_names, opts))
    drop_links(leaver, remaining, names_of(remaining_entries), opts)
  end

  defp drop_links(nil, _ids, _names, _opts), do: :ok

  defp drop_links(entry, ids, names, opts) do
    case Library.payload(entry) do
      %CharacterSheet{relationships: rels} = sheet when is_list(rels) ->
        kept = Enum.reject(rels, &links_to?(&1, ids, names))

        if length(kept) != length(rels),
          do: Library.update_payload(entry.id, %CharacterSheet{sheet | relationships: kept}, opts)

        :ok

      _ ->
        :ok
    end
  end

  defp links_to?(rel, ids, names) do
    Enum.any?(ids, &same_ref?(rel.target_id, &1)) or
      (rel.target_id in [nil, ""] and MapSet.member?(names, normalize_name(rel.target)))
  end

  defp names_of(entries) do
    for e <- entries,
        e != nil,
        %CharacterSheet{name: n} <- [Library.payload(e)],
        is_binary(n),
        normalize_name(n) != "",
        into: MapSet.new(),
        do: normalize_name(n)
  end

  defp normalize_name(n), do: n |> to_string() |> String.trim() |> String.downcase()

  # Ids have been written as both integers and strings over the years.
  defp same_ref?(a, b), do: to_string(a) == to_string(b)

  @doc """
  The campaign a character belongs to, or nil — the inverse of `by_character/2` for
  when you have the person and not the map.
  """
  @spec of_character(term(), term(), keyword()) :: term() | nil
  def of_character(owner, character_id, opts \\ []),
    do: owner |> by_character(opts) |> Map.get(to_string(character_id))

  @doc """
  A campaign's name, or the placeholder the library shows for an unnamed one.

  A frozen snapshot has no name of its own and takes its world's, so it's routed to
  the read that knows that rather than rendering as *Untitled campaign* over a story
  that plainly has a title.
  """
  @spec name(map()) :: String.t()
  def name(entry) do
    cond do
      Library.snapshot?(entry) -> Polyphony.Reading.Session.title(Library.payload(entry))
      true -> named(Library.payload(entry))
    end
  end

  defp named(%{name: n}) when is_binary(n) and n != "", do: n
  defp named(_payload), do: "Untitled campaign"
end
