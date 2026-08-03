defmodule Polyphony.Library do
  @moduledoc """
  Ownership, visibility, and the publish/fork lifecycle for owned authored entities
  (§B1): character sheets, world bibles, campaigns, and prompt-template overrides.
  **Arc is not owned here** — it is campaign-scoped and travels *inside* a published
  campaign snapshot.

  Two independent axes (see `Polyphony.ReadModels.LibraryEntry`): **visibility**
  (`private` / `unlisted` / `public`) and **live/frozen**. Access is never decided in
  this module — it is the pure `Polyphony.Library.Access` predicate. This context owns
  persistence and the three lifecycle transitions:

    * **publish** — freeze a campaign into a self-contained `Snapshot` (pinned bible +
      sheet versions + canon-only arc at the published beat) and store it as a frozen
      entry. Publishing implies freeze; visibility is a separate choice.
    * **instantiate a character** — copy a shared sheet **only** (never arc),
      version-pinned, into the actor's library as a new owned, fully editable entry.
    * **fork a campaign** — copy a published campaign at its beat, **including the arc
      snapshot**, and instantiate its embedded bible and characters as new owned,
      editable copies. After forking it is an ordinary private live branch.

  Derived entities keep a `derived_from` pointer (id + version) for attribution.
  **Everything is editable after forking, including private fields** — no restriction
  locks forked content (§B1 product stance).

  The `payload` round-trips losslessly as an Erlang term; use `payload/1` to decode a
  fetched row.
  """

  alias Polyphony.Repo
  alias Polyphony.Owner
  alias Polyphony.Authoring.CharacterSheet
  alias Polyphony.ReadModels.LibraryEntry
  alias Polyphony.Library.Snapshot

  @kinds ~w(character world_bible campaign template_override)

  @doc "The owned-entity kinds the library tracks."
  def kinds, do: @kinds

  # ── Persistence ─────────────────────────────────────────────────────────────

  @doc """
  Store a new owned entry. `attrs`: `:owner` (a `%Owner{}`, a `%User{}`, or a bare id
  coerced to a user) — or the legacy `:owner_id` — plus `:kind`, `:payload` (a domain
  struct/map), and optional `:visibility` (default `"private"`), `:frozen`,
  `:derived_from_id`, `:derived_from_version`, `:version` (default 1). A `:unlisted`
  entry is given a fresh share token automatically.
  """
  def put(attrs, opts \\ []) do
    repo = repo(opts)
    attrs = Map.new(attrs)
    visibility = to_string(Map.get(attrs, :visibility, "private"))
    owner = Owner.coerce(Map.get(attrs, :owner) || Map.fetch!(attrs, :owner_id))
    payload = assign_hue(Map.fetch!(attrs, :payload), owner, opts)

    LibraryEntry.put(repo, %{
      owner_type: Owner.type_string(owner),
      owner_id: Owner.id(owner),
      kind: to_string(Map.fetch!(attrs, :kind)),
      visibility: visibility,
      share_token: Map.get(attrs, :share_token) || token_for(visibility),
      version: Map.get(attrs, :version, 1),
      frozen: Map.get(attrs, :frozen, false),
      derived_from_id: Map.get(attrs, :derived_from_id),
      derived_from_version: Map.get(attrs, :derived_from_version),
      # Omitted for an original — `LibraryEntry.put/2` stamps it with the row's own id,
      # which can't be known until the insert has happened (§3.1d).
      root_id: Map.get(attrs, :root_id),
      payload: encode(payload)
    })
  end

  # A character's voice colour is assigned **once, here** — the single door every
  # character in the system comes through — and then stored on the sheet.
  #
  # The alternative, deriving it from position in a cast, is brittle in a way that
  # shows: remove one character and everyone after them changes colour, in the
  # transcript they already appear in as much as in the cast list. The kit's rule is
  # that a character is the same hue everywhere, and "everywhere" includes across
  # edits. Storing it also means an author can pick their own later without anything
  # else changing.
  #
  # Next in rotation for this owner, so a fresh cast spreads across the palette
  # rather than clustering. Deterministic — no randomness, which replay depends on.
  defp assign_hue(%CharacterSheet{hue: nil} = sheet, owner, opts) do
    taken =
      repo(opts)
      |> LibraryEntry.list_for_owner(Owner.type_string(owner), Owner.id(owner), [])
      |> Enum.count(&(&1.kind == "character"))

    %CharacterSheet{sheet | hue: rem(taken, CharacterSheet.hue_count()) + 1}
  end

  defp assign_hue(payload, _owner, _opts), do: payload

  @doc "Fetch a row (payload still encoded — use `payload/1`), or nil."
  def get(id, opts \\ []), do: LibraryEntry.get(repo(opts), id)

  @doc """
  Every entry owned by `owner` (a `%Owner{}`, `%User{}`, or bare id) — excludes
  archived/soft-deleted by default; `include_archived: true` / `include_deleted: true`
  opt in (§B9).
  """
  def list_for_owner(owner, opts \\ []) do
    owner = Owner.coerce(owner)
    LibraryEntry.list_for_owner(repo(opts), Owner.type_string(owner), Owner.id(owner), opts)
  end

  @doc "Public, browsable entries of a kind."
  def list_public(kind, opts \\ []), do: LibraryEntry.list_public(repo(opts), to_string(kind))

  @doc "The unlisted entry for a share token, or nil."
  def get_by_share_token(token, opts \\ []),
    do: LibraryEntry.get_by_share_token(repo(opts), token)

  @doc "Decode a fetched row's payload back into its domain struct."
  def payload(%LibraryEntry{payload: bin}), do: decode(bin)

  @doc """
  Change an entry's visibility. Moving to `:unlisted` mints a share token if the
  entry has none; the token is retained across later transitions so a shared URL
  keeps working if re-listed.
  """
  def set_visibility(id, visibility, opts \\ []) do
    repo = repo(opts)
    visibility = to_string(visibility)

    case LibraryEntry.get(repo, id) do
      nil ->
        {:error, :not_found}

      row ->
        changes = %{visibility: visibility}

        changes =
          if visibility == "unlisted" and is_nil(row.share_token),
            do: Map.put(changes, :share_token, gen_token()),
            else: changes

        {:ok, LibraryEntry.update(repo, row, changes)}
    end
  end

  @doc "Replace an entry's payload and bump its version (edits pin forward)."
  def update_payload(id, new_payload, opts \\ []) do
    repo = repo(opts)

    case LibraryEntry.get(repo, id) do
      nil ->
        {:error, :not_found}

      row ->
        {:ok,
         LibraryEntry.update(repo, row, %{payload: encode(new_payload), version: row.version + 1})}
    end
  end

  # ── Soft-delete (§B9) ─────────────────────────────────────────────────────────

  @doc "Archive an entry — hidden from default lists, fully recoverable."
  def archive(id, opts \\ []), do: stamp(id, :archived_at, now(opts), opts)

  @doc "Un-archive an entry, restoring it to default lists."
  def unarchive(id, opts \\ []), do: stamp(id, :archived_at, nil, opts)

  @doc """
  Soft-delete an entry (recoverable within the recovery window before a purge). If
  it was **published** (public/unlisted), the snapshot is resolved first — the entry
  is unpublished to `private` (tombstone), since an external consumer must not keep
  resolving deleted content. Forks are independent copies and are never touched.
  """
  def soft_delete(id, opts \\ []) do
    repo = repo(opts)

    case LibraryEntry.get(repo, id) do
      nil ->
        {:error, :not_found}

      row ->
        changes = %{deleted_at: now(opts)}
        # Resolve a published snapshot: unpublish so it stops being reachable.
        changes =
          if row.visibility in ["public", "unlisted"],
            do: Map.put(changes, :visibility, "private"),
            else: changes

        {:ok, LibraryEntry.update(repo, row, changes)}
    end
  end

  @doc """
  How long a soft-deleted entry waits before it really goes (§2.13).

  The design leans on this being a **number** rather than a claim: the trash row reads
  *gone for good in 24 days*, and the whole point of the countdown is that it's the one
  place the recovery window isn't a promise. Which only holds if something purges on
  schedule — `Polyphony.Jobs.PurgeTrash` is that something.
  """
  @spec retention_days() :: pos_integer()
  def retention_days, do: 30

  @doc """
  Days left before an entry is purged, or nil if it isn't in the trash.

  Rounded up, so "1 day" means there is still a day: rounding down would show a zero to
  someone who can still get their work back, which is the wrong way to be wrong here.
  """
  @spec days_until_purge(LibraryEntry.t(), keyword()) :: non_neg_integer() | nil
  def days_until_purge(entry, opts \\ [])
  def days_until_purge(%LibraryEntry{deleted_at: nil}, _opts), do: nil

  def days_until_purge(%LibraryEntry{deleted_at: at}, opts) do
    elapsed = NaiveDateTime.diff(now(opts), at, :second)
    remaining = retention_days() * 86_400 - elapsed

    remaining |> Kernel./(86_400) |> Float.ceil() |> trunc() |> max(0)
  end

  @doc "Everything of `owner`'s that is in the trash, oldest deletion first."
  @spec trash(term(), keyword()) :: [LibraryEntry.t()]
  def trash(owner, opts \\ []) do
    owner
    |> list_for_owner(Keyword.put(opts, :include_deleted, true))
    |> Enum.filter(&(&1.deleted_at != nil))
    |> Enum.sort_by(& &1.deleted_at, NaiveDateTime)
  end

  @doc "Everything of `owner`'s that is archived — filed away, not deleted."
  @spec archived(term(), keyword()) :: [LibraryEntry.t()]
  def archived(owner, opts \\ []) do
    owner
    |> list_for_owner(Keyword.put(opts, :include_archived, true))
    |> Enum.filter(&(&1.archived_at != nil and &1.deleted_at == nil))
  end

  @doc """
  Purge everything whose recovery window has run out. Returns how many went.

  The other half of the countdown: without this the number on the screen is a claim
  again, which is the thing the design set out to avoid.
  """
  @spec purge_expired(keyword()) :: non_neg_integer()
  def purge_expired(opts \\ []) do
    cutoff = NaiveDateTime.add(now(opts), -retention_days() * 86_400, :second)

    repo(opts)
    |> LibraryEntry.deleted_before(cutoff)
    |> Enum.map(&purge(&1.id, opts))
    |> length()
  end

  @doc "Restore a soft-deleted (or archived) entry within the recovery window."
  def restore(id, opts \\ []) do
    repo = repo(opts)

    case LibraryEntry.get(repo, id) do
      nil -> {:error, :not_found}
      row -> {:ok, LibraryEntry.update(repo, row, %{deleted_at: nil, archived_at: nil})}
    end
  end

  @doc "Hard-purge an entry — irreversible, after the recovery window / explicit confirm."
  def purge(id, opts \\ []) do
    repo = repo(opts)

    case LibraryEntry.get(repo, id) do
      nil -> {:error, :not_found}
      row -> {:ok, repo.delete!(row)}
    end
  end

  # ── Moderation hiding (§B3) ─────────────────────────────────────────────────

  @doc """
  Hide an entry from everyone but its owner and an admin.

  A **fourth axis**, deliberately separate from visibility, archiving and deletion: the
  owner's own `visibility` is left exactly as they set it, so lifting the hiding
  restores what they chose rather than what a moderator guessed. `reason` is what the
  review lane reads.
  """
  @spec hide(term(), String.t() | nil, keyword()) :: {:ok, LibraryEntry.t()} | {:error, term()}
  def hide(id, reason \\ nil, opts \\ []) do
    case get(id, opts) do
      nil ->
        {:error, :not_found}

      entry ->
        {:ok,
         LibraryEntry.update(repo(opts), entry,
           hidden_at: now(opts),
           review_reason: reason
         )}
    end
  end

  @doc "Un-hide it. The owner's visibility comes back untouched, which is the point."
  @spec unhide(term(), keyword()) :: {:ok, LibraryEntry.t()} | {:error, term()}
  def unhide(id, opts \\ []) do
    case get(id, opts) do
      nil -> {:error, :not_found}
      entry -> {:ok, LibraryEntry.update(repo(opts), entry, hidden_at: nil, review_reason: nil)}
    end
  end

  @doc "Is this entry hidden by moderation?"
  @spec hidden?(LibraryEntry.t()) :: boolean()
  def hidden?(%LibraryEntry{hidden_at: at}), do: not is_nil(at)

  @doc "Everything currently hidden — the review lane's list."
  @spec hidden(keyword()) :: [LibraryEntry.t()]
  def hidden(opts \\ []), do: LibraryEntry.list_hidden(repo(opts))

  @doc """
  Everything `owner` has shared — public **and** unlisted.

  What a suspension has to reach. Hiding only the public half would leave a suspended
  person able to open their own share link and fork their way back in; starting again
  should mean starting again.
  """
  @spec shared_by(term(), keyword()) :: [LibraryEntry.t()]
  def shared_by(owner, opts \\ []) do
    owner = Owner.coerce(owner)

    LibraryEntry.list_shared_for_owner(
      repo(opts),
      Owner.type_string(owner),
      Owner.id(owner)
    )
  end

  @doc """
  Is this entry a **published snapshot** rather than a working artifact?

  They share the `"campaign"` kind because they share a table, and nothing else: a
  snapshot can't be played, finished, cast or reviewed, and its payload is a
  `Library.Snapshot` with none of a campaign's fields. Anything that means "a campaign
  the owner is working on" must ask this rather than infer it from `kind`, which is how
  a frozen copy ends up in a list that then tries to read `:character_ids` off it.
  """
  @spec snapshot?(LibraryEntry.t()) :: boolean()
  def snapshot?(%LibraryEntry{kind: "campaign", frozen: true}), do: true
  def snapshot?(%LibraryEntry{}), do: false

  @doc """
  The published snapshots taken from `entry`, newest first — empty if it's never been
  published.
  """
  @spec publications_of(LibraryEntry.t() | term(), keyword()) :: [LibraryEntry.t()]
  def publications_of(%LibraryEntry{} = entry, opts), do: publications_of(entry.id, opts)

  def publications_of(id, opts) do
    id
    |> copies_of(opts)
    |> Enum.filter(&snapshot?/1)
    |> Enum.sort_by(& &1.inserted_at, {:desc, NaiveDateTime})
  end

  def publications_of(entry_or_id), do: publications_of(entry_or_id, [])

  @doc "Has this campaign been published? (Its snapshot is a separate entry.)"
  @spec published?(LibraryEntry.t() | term(), keyword()) :: boolean()
  def published?(entry_or_id, opts \\ []), do: publications_of(entry_or_id, opts) != []

  @doc "Is this entry live (neither archived nor soft-deleted)?"
  def live?(%LibraryEntry{archived_at: nil, deleted_at: nil}), do: true
  def live?(%LibraryEntry{}), do: false

  defp stamp(id, field, value, opts) do
    repo = repo(opts)

    case LibraryEntry.get(repo, id) do
      nil -> {:error, :not_found}
      row -> {:ok, LibraryEntry.update(repo, row, %{field => value})}
    end
  end

  # ── Publish ─────────────────────────────────────────────────────────────────

  @doc """
  Publish a campaign: build a frozen `Snapshot` and store it as a `frozen: true`
  entry. Publishing implies freeze; `:visibility` (default `"public"`) is a separate
  choice, and `:include_proposed` (default `false`) resolves the proposed arc tail.

  `attrs` are the campaign's live dependencies (see `Snapshot.build/2`) plus `:owner`
  (or the legacy `:owner_id`), and optional `:derived_from_id` / `:derived_from_version`.
  """
  def publish_campaign(attrs, opts \\ []) do
    attrs = Map.new(attrs)

    snapshot =
      Snapshot.build(attrs, include_proposed: Keyword.get(opts, :include_proposed, false))

    # A snapshot descends from the campaign it froze. Recorded structurally rather than
    # only inside the payload, so "has this been published?" is an indexed read like
    # every other provenance question (§3.1d) — and so a republish groups with the
    # earlier one instead of looking like an unrelated story.
    campaign_id = Map.get(attrs, :derived_from_id) || live_campaign_id(attrs, opts)

    put(
      %{
        # `:owner` or the legacy `:owner_id`, matching `put/2` — the campaign screen
        # passes the former, and demanding the latter meant the Publish button raised.
        owner: Map.get(attrs, :owner) || Map.fetch!(attrs, :owner_id),
        kind: "campaign",
        visibility: Keyword.get(opts, :visibility, "public"),
        frozen: true,
        derived_from_id: campaign_id,
        derived_from_version: Map.get(attrs, :derived_from_version),
        root_id: campaign_id && root_id_of(campaign_id, opts),
        payload: snapshot
      },
      opts
    )
  end

  # `campaign_id` is a library id when the snapshot was built from a stored campaign and
  # an arbitrary string when it wasn't — an export, a scene-scoped id, a fixture. Only
  # the former is a real ancestor, and asking the database about the latter is a cast
  # error rather than a miss, so the shape is checked before the lookup.
  defp live_campaign_id(attrs, opts) do
    with id when not is_nil(id) <- library_id(Map.get(attrs, :campaign_id)),
         %LibraryEntry{frozen: false} = entry <- get(id, opts) do
      entry.id
    else
      _ -> nil
    end
  end

  defp library_id(id) when is_integer(id), do: id

  defp library_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp library_id(_), do: nil

  defp root_id_of(id, opts) do
    case get(id, opts) do
      nil -> nil
      entry -> root_of(entry)
    end
  end

  # ── Copy-on-instantiate / copy-on-fork ───────────────────────────────────────

  @doc """
  Copy an entry into `new_owner`'s library as a new **private, live, fully editable**
  entry, version-pinned to the source through `derived_from`.

  The one primitive behind every "this is a template" relationship in the design
  (§2.5b): attaching a world to a campaign, saving someone else's world, and saving a
  campaign's world back to your library are all this, in different directions.

  A copy carries only the **payload**. Arc lives in `arc_entries` keyed by subject id,
  so a copy starts with none — which is the point: two campaigns cannot accumulate
  different histories on one bible, and a template that has been started from stays a
  template.
  """
  @spec copy(LibraryEntry.t(), term(), keyword()) :: LibraryEntry.t()
  def copy(%LibraryEntry{} = source, new_owner, opts \\ []) do
    put(
      %{
        owner: new_owner,
        kind: source.kind,
        visibility: "private",
        frozen: false,
        derived_from_id: source.id,
        derived_from_version: source.version,
        # Carry the *root*, not the parent, so a fork of a fork still groups under the
        # thing it all started from (§3.1d) rather than under its immediate ancestor.
        root_id: source.root_id || source.id,
        payload: payload(source)
      },
      opts
    )
  end

  @doc "Instantiate a shared character (`copy/3` with the kind pinned)."
  def instantiate_character(%LibraryEntry{kind: "character"} = source, new_owner, opts \\ []),
    do: copy(source, new_owner, opts)

  @doc """
  The live entries copied from `id` — what "used in 2 campaigns" counts.

  Derived rather than stored, and derived from the copies rather than from the
  campaigns, because the copy is the thing that exists: one copy per attach, and it
  survives its campaign being renamed or the template being edited.
  """
  @spec copies_of(term(), keyword()) :: [LibraryEntry.t()]
  def copies_of(id, opts \\ []), do: LibraryEntry.copies_of(repo(opts), id)

  @doc "How many live copies were taken from `id`."
  @spec copy_count(term(), keyword()) :: non_neg_integer()
  def copy_count(id, opts \\ []), do: id |> copies_of(opts) |> length()

  @doc """
  Every live entry descended from the same original as `entry` — including it.

  What Browse groups a story's forks by and what the library groups a world's copies
  by (§3.1d). A parent pointer alone would mean walking the chain per row, which is the
  wrong shape for rendering a list.
  """
  @spec family(LibraryEntry.t() | term(), keyword()) :: [LibraryEntry.t()]
  def family(entry_or_id, opts \\ [])

  def family(%LibraryEntry{} = entry, opts),
    do: LibraryEntry.family(repo(opts), root_of(entry), opts)

  def family(id, opts) do
    case get(id, opts) do
      nil -> []
      entry -> family(entry, opts)
    end
  end

  @doc "The original an entry descends from — itself, for an original."
  @spec root_of(LibraryEntry.t()) :: integer()
  def root_of(%LibraryEntry{root_id: root, id: id}), do: root || id

  @doc """
  Where a copy came from: `{parent, root}` entries, either of which may be nil.

  Attribution is recorded on every derived entry and has never been shown. A reader
  should always be able to walk back to where something started (§3.1d).
  """
  @spec provenance(LibraryEntry.t(), keyword()) ::
          {LibraryEntry.t() | nil, LibraryEntry.t() | nil}
  def provenance(%LibraryEntry{} = entry, opts \\ []) do
    parent = entry.derived_from_id && get(entry.derived_from_id, opts)
    root = if root_of(entry) == entry.id, do: nil, else: get(root_of(entry), opts)
    {parent, root}
  end

  @doc """
  Mint a **new** share token, invalidating the old one.

  Deliberately destructive and deliberately explicit: the design's own copy is *a new
  link breaks the old one*, which is the entire reason the control exists — it is how
  you un-share something you shared with the wrong person.
  """
  @spec rotate_share_token(term(), keyword()) :: {:ok, LibraryEntry.t()} | {:error, term()}
  def rotate_share_token(id, opts \\ []) do
    repo = repo(opts)

    case LibraryEntry.get(repo, id) do
      nil -> {:error, :not_found}
      row -> {:ok, LibraryEntry.update(repo, row, %{share_token: gen_token()})}
    end
  end

  @doc """
  Is `owner` already using `name` for something of this `kind`?

  Names are not unique in the database — two campaigns may legitimately both have a
  character called "the bellman" — but within one owner's list of *worlds* a repeat
  is almost always a mistake heading for confusion, and the design catches it at the
  field (`ux/polyphony-world.html` §03, "you already have a world called Saltmarch").
  Compared case- and whitespace-insensitively, because that is how a person reads it.
  `except` skips one entry, so saving a world under its own name is not a clash.
  """
  @spec name_taken?(term(), String.t(), String.t(), keyword()) :: boolean()
  def name_taken?(owner, kind, name, opts \\ []) do
    case normalize_name(name) do
      "" ->
        false

      wanted ->
        except = Keyword.get(opts, :except)

        owner
        |> list_for_owner(opts)
        |> Enum.any?(fn e ->
          e.kind == to_string(kind) and e.id != except and
            normalize_name(payload_name(e)) == wanted
        end)
    end
  end

  defp payload_name(entry) do
    case payload(entry) do
      %{name: n} -> n
      _ -> nil
    end
  end

  defp normalize_name(name), do: name |> to_string() |> String.trim() |> String.downcase()

  @doc """
  Fork a published campaign into `new_owner`'s library. Copies the whole campaign at
  its published beat — **including the arc snapshot** — and instantiates the embedded
  bible and characters as new owned, editable copies. The forked campaign itself is a
  **private, live** entry referencing those new copies (a normal branch), with a
  `derived_from` pointer to the published source.

  Returns `%{campaign: entry, bible: entry | nil, characters: [entry]}`.
  """
  def fork_campaign(
        %LibraryEntry{kind: "campaign", frozen: true} = published,
        new_owner,
        opts \\ []
      ) do
    %Snapshot{} = snap = payload(published)

    bible_entry =
      case snap.bible do
        nil ->
          nil

        bible ->
          put(
            %{owner_id: new_owner, kind: "world_bible", visibility: "private", payload: bible},
            opts
          )
      end

    character_entries =
      Enum.map(snap.characters, fn pinned ->
        put(
          %{
            owner_id: new_owner,
            kind: "character",
            visibility: "private",
            derived_from_id: Map.get(pinned, :source_id),
            derived_from_version: Map.get(pinned, :source_version),
            payload: Map.fetch!(pinned, :sheet)
          },
          opts
        )
      end)

    # The forked campaign is live: it points at the new owned copies and carries the
    # copied arc snapshot. Everything it references is private and fully editable.
    live_campaign = %{
      kind: :campaign_ref,
      bible_entry_id: bible_entry && bible_entry.id,
      character_entry_ids: Enum.map(character_entries, & &1.id),
      arc: snap.arc,
      forked_at_beat: snap.published_beat
    }

    campaign_entry =
      put(
        %{
          owner_id: new_owner,
          kind: "campaign",
          visibility: "private",
          frozen: false,
          derived_from_id: published.id,
          derived_from_version: published.version,
          payload: live_campaign
        },
        opts
      )

    %{campaign: campaign_entry, bible: bible_entry, characters: character_entries}
  end

  # ── Codec + helpers ──────────────────────────────────────────────────────────

  defp repo(opts), do: Keyword.get(opts, :repo, Repo)

  defp encode(payload), do: :erlang.term_to_binary(payload)
  # `:safe` refuses to fabricate atoms/modules; every embedded struct
  # (CharacterSheet, WorldBible, Snapshot, …) is already loaded.
  defp decode(bin), do: :erlang.binary_to_term(bin, [:safe])

  defp token_for("unlisted"), do: gen_token()
  defp token_for(_visibility), do: nil

  defp now(opts),
    do:
      Keyword.get_lazy(opts, :now, fn ->
        NaiveDateTime.truncate(NaiveDateTime.utc_now(), :microsecond)
      end)

  # A share token is read-model state (never event-sourced/replayed), so a strong
  # random token is appropriate here — unlike aggregate logic, this isn't replayed.
  defp gen_token, do: 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
