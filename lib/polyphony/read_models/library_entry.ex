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
    field(:owner_id, :string)
    field(:kind, :string)
    field(:visibility, :string, default: "private")
    field(:share_token, :string)
    field(:version, :integer, default: 1)
    field(:derived_from_id, :integer)
    field(:derived_from_version, :integer)
    field(:frozen, :boolean, default: false)
    field(:payload, :binary)
    # Soft-delete (§B9): archived hides from default lists; deleted is the
    # recoverable delete before a purge.
    field(:archived_at, :naive_datetime_usec)
    field(:deleted_at, :naive_datetime_usec)
    timestamps(type: :naive_datetime_usec)
  end

  def put(repo, attrs), do: repo.insert!(struct(__MODULE__, attrs))

  def get(repo, id), do: repo.get(__MODULE__, id)

  def update(repo, %__MODULE__{} = row, changes),
    do: row |> Ecto.Changeset.change(changes) |> repo.update!()

  @doc """
  Every entry owned by `owner_id`, newest first. Excludes soft-deleted and archived
  entries by default (§B9); `include_archived: true` / `include_deleted: true` opt in.
  """
  def list_for_owner(repo, owner_id, opts \\ []) do
    oid = to_string(owner_id)

    from(e in __MODULE__, where: e.owner_id == ^oid, order_by: [desc: e.inserted_at])
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
