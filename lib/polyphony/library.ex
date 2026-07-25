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
  alias Polyphony.ReadModels.LibraryEntry
  alias Polyphony.Library.Snapshot

  @kinds ~w(character world_bible campaign template_override)

  @doc "The owned-entity kinds the library tracks."
  def kinds, do: @kinds

  # ── Persistence ─────────────────────────────────────────────────────────────

  @doc """
  Store a new owned entry. `attrs`: `:owner_id`, `:kind`, `:payload` (a domain
  struct/map), plus optional `:visibility` (default `"private"`), `:frozen`,
  `:derived_from_id`, `:derived_from_version`, `:version` (default 1). A `:unlisted`
  entry is given a fresh share token automatically.
  """
  def put(attrs, opts \\ []) do
    repo = repo(opts)
    attrs = Map.new(attrs)
    visibility = to_string(Map.get(attrs, :visibility, "private"))

    LibraryEntry.put(repo, %{
      owner_id: to_string(Map.fetch!(attrs, :owner_id)),
      kind: to_string(Map.fetch!(attrs, :kind)),
      visibility: visibility,
      share_token: Map.get(attrs, :share_token) || token_for(visibility),
      version: Map.get(attrs, :version, 1),
      frozen: Map.get(attrs, :frozen, false),
      derived_from_id: Map.get(attrs, :derived_from_id),
      derived_from_version: Map.get(attrs, :derived_from_version),
      payload: encode(Map.fetch!(attrs, :payload))
    })
  end

  @doc "Fetch a row (payload still encoded — use `payload/1`), or nil."
  def get(id, opts \\ []), do: LibraryEntry.get(repo(opts), id)

  @doc "Every entry owned by `owner_id`."
  def list_for_owner(owner_id, opts \\ []), do: LibraryEntry.list_for_owner(repo(opts), owner_id)

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

  # ── Publish ─────────────────────────────────────────────────────────────────

  @doc """
  Publish a campaign: build a frozen `Snapshot` and store it as a `frozen: true`
  entry. Publishing implies freeze; `:visibility` (default `"public"`) is a separate
  choice, and `:include_proposed` (default `false`) resolves the proposed arc tail.

  `attrs` are the campaign's live dependencies (see `Snapshot.build/2`) plus
  `:owner_id`, and optional `:derived_from_id` / `:derived_from_version`.
  """
  def publish_campaign(attrs, opts \\ []) do
    attrs = Map.new(attrs)

    snapshot =
      Snapshot.build(attrs, include_proposed: Keyword.get(opts, :include_proposed, false))

    put(
      %{
        owner_id: Map.fetch!(attrs, :owner_id),
        kind: "campaign",
        visibility: Keyword.get(opts, :visibility, "public"),
        frozen: true,
        derived_from_id: Map.get(attrs, :derived_from_id),
        derived_from_version: Map.get(attrs, :derived_from_version),
        payload: snapshot
      },
      opts
    )
  end

  # ── Copy-on-instantiate / copy-on-fork ───────────────────────────────────────

  @doc """
  Instantiate a shared character into `new_owner`'s library: copy the **sheet only**
  (never arc), version-pinned to the source, as a new **private, live, fully
  editable** owned entry. Returns the new row.
  """
  def instantiate_character(%LibraryEntry{kind: "character"} = source, new_owner, opts \\ []) do
    put(
      %{
        owner_id: new_owner,
        kind: "character",
        visibility: "private",
        frozen: false,
        derived_from_id: source.id,
        derived_from_version: source.version,
        payload: payload(source)
      },
      opts
    )
  end

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

  # A share token is read-model state (never event-sourced/replayed), so a strong
  # random token is appropriate here — unlike aggregate logic, this isn't replayed.
  defp gen_token, do: 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
