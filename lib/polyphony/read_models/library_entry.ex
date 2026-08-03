defmodule Polyphony.ReadModels.LibraryEntry do
  @moduledoc """
  The owned-entity library table (§B1): one row per owned authored entity — a
  character sheet, world bible, campaign, or prompt-template override.

  Two independent axes live here (§B1):

    * **visibility** — `private` (default) / `unlisted` (share-token URL) / `public`;
    * **live/frozen** — a working entry references the owner's live library; a
      published snapshot embeds pinned dependencies and is `frozen: true`.

  `payload` is an opaque Erlang term (`Polyphony.Library` owns the codec) so nested
  authored structs (`CharacterSheet`, `WorldBible`, `Library.Snapshot`) round-trip
  losslessly. Access decisions are **never** made here — they live in the pure
  `Polyphony.Library.Access` predicate.
  """
  use Ecto.Schema
  import Ecto.Query

  schema "library_entries" do
    # Owner indirection (§P2/§P8): `owner_type` + `owner_id` together identify the
    # owner; today always a user, shaped so it can become an org without a migration.
    field(:owner_type, :string, default: "user")
    field(:owner_id, :string)
    field(:kind, :string)
    field(:visibility, :string, default: "private")
    field(:share_token, :string)
    field(:version, :integer, default: 1)
    field(:derived_from_id, :integer)
    field(:derived_from_version, :integer)
    # Root identity (§3.1d): the original every copy descends from, stamped once so
    # grouping a list is one indexed read rather than a chain-walk per row. An
    # original's root is itself.
    field(:root_id, :integer)
    field(:frozen, :boolean, default: false)
    field(:payload, :binary)
    # Soft-delete (§B9): archived hides from default lists; deleted is the
    # recoverable delete before a purge.
    field(:archived_at, :naive_datetime_usec)
    field(:deleted_at, :naive_datetime_usec)
    timestamps(type: :naive_datetime_usec)
  end

  # An entry with no root of its own **is** the root — written back after the insert
  # because it can't be known before the id exists. Explicit rather than left null so
  # no query ever has to case on it (§3.1d).
  def put(repo, attrs) do
    row = repo.insert!(struct(__MODULE__, attrs))

    # Qualified: `import Ecto.Query` brings its own `update/3` into scope.
    if is_nil(row.root_id),
      do: __MODULE__.update(repo, row, root_id: row.id),
      else: row
  end

  def get(repo, id), do: repo.get(__MODULE__, id)

  def update(repo, %__MODULE__{} = row, changes),
    do: row |> Ecto.Changeset.change(changes) |> repo.update!()

  @doc """
  Every entry owned by `{owner_type, owner_id}`, newest first. Excludes soft-deleted
  and archived entries by default (§B9); `include_archived: true` / `include_deleted:
  true` opt in.
  """
  def list_for_owner(repo, owner_type, owner_id, opts \\ []) do
    ot = to_string(owner_type)
    oid = to_string(owner_id)

    from(e in __MODULE__,
      where: e.owner_type == ^ot and e.owner_id == ^oid,
      order_by: [desc: e.inserted_at]
    )
    |> visible(opts)
    |> repo.all()
  end

  @doc "Public, browsable entries of a `kind` — never soft-deleted or archived."
  def list_public(repo, kind) do
    k = to_string(kind)

    from(e in __MODULE__,
      where: e.kind == ^k and e.visibility == "public",
      order_by: [desc: e.inserted_at]
    )
    |> visible([])
    |> repo.all()
  end

  @doc "The unlisted, live entry matching a share token, or nil (a deleted one is gone)."
  def get_by_share_token(repo, token) when is_binary(token) do
    repo.one(from(e in __MODULE__, where: e.share_token == ^token and is_nil(e.deleted_at)))
  end

  def get_by_share_token(_repo, _), do: nil

  @doc "Entries soft-deleted before `cutoff` — whose recovery window has run out (§2.13)."
  def deleted_before(repo, cutoff) do
    repo.all(from(e in __MODULE__, where: not is_nil(e.deleted_at) and e.deleted_at < ^cutoff))
  end

  @doc "Live entries copied from `source_id` (§2.5b provenance)."
  def copies_of(repo, source_id) do
    repo.all(
      from(e in __MODULE__,
        where: e.derived_from_id == ^source_id and is_nil(e.deleted_at),
        order_by: [asc: e.inserted_at]
      )
    )
  end

  @doc """
  Every live entry sharing `root_id` — an original and everything descended from it.

  One indexed read, which is the point of storing a root at all: three forks share a
  title until somebody renames one, and a flat list of near-identical names is
  unusable (§3.1d).
  """
  def family(repo, root_id, opts \\ []) do
    from(e in __MODULE__, where: e.root_id == ^root_id, order_by: [asc: e.inserted_at])
    |> visible(opts)
    |> repo.all()
  end

  @doc "Public entries of a `kind`, grouped by root — for Browse's by-author grouping."
  def list_public_by_root(repo, kind) do
    repo
    |> list_public(kind)
    |> Enum.group_by(&(&1.root_id || &1.id))
  end

  # Default-hide soft-deleted and archived rows; callers opt in explicitly.
  defp visible(query, opts) do
    query
    |> then(fn q ->
      if opts[:include_deleted], do: q, else: from(e in q, where: is_nil(e.deleted_at))
    end)
    |> then(fn q ->
      if opts[:include_archived], do: q, else: from(e in q, where: is_nil(e.archived_at))
    end)
  end
end
