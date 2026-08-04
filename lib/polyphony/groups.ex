defmodule Polyphony.Groups do
  @moduledoc """
  Groups as authored artifacts: creating them, who is in them, and writing a
  character from one.

  A group is a library entry like a character or a world (`Polyphony.Library`,
  kind `"group"`), so it inherits ownership, visibility, archiving and versioning
  without any of that being rebuilt. What lives here is the part that's specific:
  membership, and the seeding that membership is a starting point for.

  ## Membership is the authoritative direction

  It's stored on the **group**, as an ordered list of character ids, and a
  character's groups are derived by asking which groups hold them
  (`for_character/2`). One direction is authoritative on purpose: the design's
  audience rule is that *groups are named, not expanded — the membership moves*,
  so "who does the Tidewatch mean right now" has to be one read of one record, and
  it must be impossible for the two sides to disagree.

  Membership is by **stable library id**, never by name — the same rule as
  everywhere else since §5.2, so renaming a character can't drop them out of a
  group that a secret points at.

  ## Joining doesn't backfill

  `add_member/3` puts someone in a group and does nothing else. It deliberately
  does *not* seed them with what the group knows: the design is explicit that if
  Wren joins the Tidewatch in scene 9 she doesn't silently gain its secrets, she
  learns them in a scene — the reveal is fiction, not a migration, the same
  principle as world-arc catch-up. Seeding happens once, when a character is
  *written from* a group (`write_character/3`).

  ## Where the authoring happens

  `PolyphonyWeb.GroupEditorLive` writes one, and it is what calls `create/3`,
  `update_fields/3` and — through **Tell the members** — `Authoring.GroupArc.fan_out/3`.
  That last one is a button rather than a consequence of saving, and deliberately:
  editing a template reaches nobody, so propagating on save would be the silent
  propagation this whole design exists to refuse.
  """

  alias Polyphony.Authoring.{CharacterSheet, Group}
  alias Polyphony.Library

  @doc "Every group owned by `owner`, newest last."
  @spec list(term(), keyword()) :: [map()]
  def list(owner, opts \\ []) do
    owner
    |> Library.list_for_owner(opts)
    |> Enum.filter(&(&1.kind == Group.kind()))
  end

  @doc "Create a group. Returns the library entry."
  @spec create(term(), Group.t(), keyword()) :: map()
  def create(owner, %Group{} = group, opts \\ []),
    do: Library.put(%{owner: owner, kind: Group.kind(), payload: group}, opts)

  @doc "The group behind a library entry id, or nil if it isn't one."
  @spec get(term(), keyword()) :: Group.t() | nil
  def get(id, opts \\ []) do
    with entry when not is_nil(entry) <- Library.get(id, opts),
         %Group{} = group <- Library.payload(entry) do
      group
    else
      _ -> nil
    end
  end

  @doc """
  Add a character to a group, by library id.

  Idempotent, and order-preserving so the roster doesn't shuffle. Adds membership
  and nothing else — see the moduledoc on why joining doesn't backfill knowledge.
  """
  @spec add_member(term(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def add_member(group_id, character_id, opts \\ []) do
    update(group_id, opts, fn group ->
      id = to_string(character_id)
      %Group{group | member_ids: append_unique(group.member_ids, id)}
    end)
  end

  @doc "Remove a character from a group. Removing someone they never joined is a no-op."
  @spec remove_member(term(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def remove_member(group_id, character_id, opts \\ []) do
    update(group_id, opts, fn group ->
      id = to_string(character_id)
      %Group{group | member_ids: Enum.reject(group.member_ids || [], &(&1 == id))}
    end)
  end

  @doc """
  The character ids in a group — what an audience naming it resolves to *now*.

  Empty is a legitimate answer, not an error: the design points out that empty
  groups are how you set a trap before anyone walks into it.
  """
  @spec member_ids(term(), keyword()) :: [String.t()]
  def member_ids(group_id, opts \\ []) do
    case get(group_id, opts) do
      %Group{member_ids: ids} -> ids || []
      _ -> []
    end
  end

  @doc """
  The groups `character_id` belongs to, among `owner`'s groups.

  Derived rather than stored, so the two directions can't disagree.
  """
  @spec for_character(term(), term(), keyword()) :: [map()]
  def for_character(owner, character_id, opts \\ []) do
    id = to_string(character_id)

    owner
    |> list(opts)
    |> Enum.filter(fn entry ->
      case Library.payload(entry) do
        %Group{member_ids: ids} -> id in (ids || [])
        _ -> false
      end
    end)
  end

  @doc """
  Write a new character from a group: seed their sheet from it, and join them to it.

  This is the one path that both seeds and joins, because it's the one moment where
  both are true — the person is being brought into existence *as* one of them. The
  seed is a copy taken now; the membership is live from here on.

  `sheet` is whatever the author has already written (often just a name); anything
  on it wins over the group's version of the same field.
  """
  @spec write_character(term(), term(), CharacterSheet.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def write_character(owner, group_id, %CharacterSheet{} = sheet, opts \\ []) do
    case get(group_id, opts) do
      %Group{} = group ->
        entry =
          Library.put(
            %{owner: owner, kind: "character", payload: Group.seed(group, sheet)},
            opts
          )

        {:ok, _} = add_member(group_id, entry.id, opts)
        {:ok, entry}

      _ ->
        {:error, :not_found}
    end
  end

  @doc "Replace a group's authored fields, leaving its membership alone."
  @spec update_fields(term(), Group.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_fields(group_id, %Group{} = fields, opts \\ []) do
    update(group_id, opts, fn group ->
      %Group{fields | member_ids: group.member_ids, hue: fields.hue || group.hue}
    end)
  end

  defp update(group_id, opts, fun) do
    case get(group_id, opts) do
      %Group{} = group -> Library.update_payload(group_id, fun.(group), opts)
      _ -> {:error, :not_found}
    end
  end

  defp append_unique(ids, id) do
    ids = ids || []
    if id in ids, do: ids, else: ids ++ [id]
  end
end
