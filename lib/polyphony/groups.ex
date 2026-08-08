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

  require Logger

  alias Polyphony.Authoring.{CharacterSheet, Group}
  alias Polyphony.Library

  @doc """
  Every group owned by `owner`, newest last.

  The **library shelf's** read: everything the author has, banded by campaign. A campaign
  hub wants `list_for_campaign/3` instead.
  """
  @spec list(term(), keyword()) :: [map()]
  def list(owner, opts \\ []) do
    owner
    |> Library.list_for_owner(opts)
    |> Enum.filter(&(&1.kind == Group.kind()))
  end

  @doc """
  The groups written in `campaign_id` — a campaign hub's read.

  This used to be `list/2`, which is every group the author owns, so a second campaign's
  collectives appeared on the first campaign's hub and the count in the card header was
  the library's count. Scoping it is the whole of STR-68.

  A group with no campaign appears here for **nobody**, and there should be none to
  appear: `create/3` refuses to write one and the backfill trashed the rows that
  predated the rule. `orphans/2` is the check that this stayed true.
  """
  @spec list_for_campaign(term(), term(), keyword()) :: [map()]
  def list_for_campaign(owner, campaign_id, opts \\ [])
  def list_for_campaign(_owner, nil, _opts), do: []

  def list_for_campaign(owner, campaign_id, opts) do
    want = to_string(campaign_id)
    owner |> list(opts) |> Enum.filter(&(campaign_id_of(&1) == want))
  end

  @doc """
  The author's groups belonging to no campaign. **This should always be empty.**

  Not a supported state and not a band on a shelf — a diagnostic. `create/3` refuses to
  write one, and the backfill trashed the rows that predated the rule, so anything here
  is a row that got in some way nobody has accounted for. It is worth being able to find
  precisely because it can't be reached any other way: a group with no campaign is on no
  hub, so without this read it would be invisible and permanent.

  Whatever surfaces it should present it as an error with a way to delete it, rather
  than a heading to file things under. Supporting the class is what this ticket removed;
  being able to *see* one is what stops it quietly accumulating.
  """
  @spec orphans(term(), keyword()) :: [map()]
  def orphans(owner, opts \\ []),
    do: owner |> list(opts) |> Enum.filter(&is_nil(campaign_id_of(&1)))

  # `Map.get` rather than `group.campaign_id`, because a payload stored before the field
  # existed decodes without the key — see `Group.load/1`. Compared as a string, since a
  # library id arrives as an integer from the database and a string from a URL.
  defp campaign_id_of(entry) do
    case Library.payload(entry) do
      %Group{} = group -> group |> Map.get(:campaign_id) |> presence()
      _ -> nil
    end
  end

  defp presence(nil), do: nil
  defp presence(id), do: to_string(id)

  @doc """
  Fill in `campaign_id` on every group that predates the field. Returns what it changed.

  Two ways to tell which campaign a group belongs to, tried in that order, and the
  second is the one that matters most on real data:

    * **Its world.** A group written from a campaign hub points at that campaign's own
      copied bible, and no other campaign holds it. Exact when it resolves.
    * **Its members.** A group written from the **library** points at the *template*
      bible instead, which no campaign holds — the case the world key could never
      answer, and the reported bug. Its members still say where it belongs, because
      characters cannot cross campaigns.

  Members are not a fallback I invented: the library shelf has grouped these rows by
  `campaign_of_members/3` since it was built, and its comment says why it is
  unambiguous. Backfilling on the world key alone would have moved every one of those
  groups out of the campaign the shelf currently files it under and into the orphan
  band — a migration visibly *undoing* correct information the app was already showing.

  **A group neither answers for is trashed, not left unplaced.** A group belonging to no
  campaign is not a state this app supports: it appears on no hub, so it is unreachable
  from the story it was written for, and keeping the read paths that tolerate one means
  carrying compatibility logic for a class that can no longer be created. Inventing a
  campaign would be worse — that files somebody's writing inside a story it was never
  part of, where it looks like it belongs — so the third option is to stop having them.

  **Trashed rather than purged**, the same choice `Library.trash_orphaned_characters/1`
  makes: `soft_delete/2` puts them on the trash shelf with the ordinary recovery window,
  so anything this catches that somebody wanted is one Restore away and
  `Jobs.PurgeTrash` finishes on the usual clock. This runs unattended over every row and
  irreversibility is not a property to hand that.

  Owner is checked before assigning. Library ids come from one sequence so a cross-owner
  match shouldn't be possible, but "shouldn't be possible" is the wrong thing to rely on
  in the one pass that rewrites every row unattended.
  """
  @spec backfill_campaigns(keyword()) :: %{placed: [map()], trashed: [term()]}
  def backfill_campaigns(opts \\ []) do
    campaigns = "campaign" |> Library.of_kind(opts) |> Enum.reject(&Library.snapshot?/1)
    by_bible = index(campaigns, &List.wrap(Map.get(&1, :bible_id)))
    by_character = index(campaigns, &(Map.get(&1, :character_ids) || []))

    # Decide for every row first, then act. Writing from inside the predicate that
    # decides is how a pass like this ends up half-applied when one row raises.
    {placed, unplaceable} =
      "group"
      |> Library.of_kind(opts)
      |> Enum.filter(&placeable?/1)
      |> Enum.map(&{&1, campaign_for(&1, by_bible, by_character)})
      |> Enum.split_with(fn {_entry, campaign} -> campaign != nil end)

    %{
      placed: for({entry, campaign} <- placed, do: place(entry, campaign, opts)),
      trashed: for({entry, _none} <- unplaceable, do: trash(entry, opts))
    }
  end

  # Already scoped, or already in the trash. Both are rows this has nothing to say about.
  defp placeable?(entry), do: is_nil(campaign_id_of(entry)) and is_nil(entry.deleted_at)

  # `{referenced id => campaign entry}`, for whichever ids `refs` pulls off the payload.
  defp index(campaigns, refs) do
    for campaign <- campaigns,
        payload = Library.payload(campaign),
        is_map(payload),
        ref <- refs.(payload),
        ref != nil,
        into: %{},
        do: {to_string(ref), campaign}
  end

  # Pure: which campaign this group belongs to, or nil.
  defp campaign_for(entry, by_bible, by_character) do
    case Library.payload(entry) do
      %Group{} = payload ->
        group = Group.load(payload)

        owned_by(by_bible[to_string(group.world_bible_id)], entry) ||
          Enum.find_value(group.member_ids || [], &owned_by(by_character[to_string(&1)], entry))

      other ->
        # Not a group at all, whatever the `kind` column says. Left alone rather than
        # trashed: this function's remit is groups with no campaign, and a row it can't
        # even decode is not one of those — deleting it would be acting on something
        # nobody here understands.
        Logger.warning("[groups] entry ##{entry.id} isn't a group payload: #{inspect(other)}")
        nil
    end
  end

  defp place(entry, campaign, opts) do
    group = entry |> Library.payload() |> Group.load()
    {:ok, _} = Library.update_payload(entry.id, %Group{group | campaign_id: campaign.id}, opts)
    %{id: entry.id, campaign_id: campaign.id}
  end

  defp trash(entry, opts) do
    {:ok, _} = Library.soft_delete(entry.id, opts)
    Logger.info("[groups] entry ##{entry.id} belongs to no campaign — trashed")
    entry.id
  end

  defp owned_by(nil, _entry), do: nil

  defp owned_by(campaign, entry) do
    if campaign.owner_type == entry.owner_type and
         to_string(campaign.owner_id) == to_string(entry.owner_id),
       do: campaign
  end

  @doc """
  Create a group in a campaign. Returns the library entry.

  **`campaign_id` is required, and its absence raises** rather than producing a group
  that belongs nowhere. Groups scoped to no campaign are the class STR-68 existed to
  remove: they appeared on every hub or on none, and they cannot be reached from the
  story they were written for. One is now a bug in whatever called this, and it says so
  at the moment of the write rather than becoming a row somebody finds later.

  This is deliberately a raise and not an `{:error, _}`. There is no user-facing
  decision here and no recovery a screen could offer — a group is only ever written from
  inside a campaign, so a caller without one has lost track of where it is, and the only
  useful response is a stack trace pointing at it.
  """
  @spec create(term(), Group.t(), keyword()) :: map()
  def create(owner, group, opts \\ [])

  def create(_owner, %Group{campaign_id: nil}, _opts) do
    raise ArgumentError,
          "a group must be written in a campaign — `campaign_id` is the scope key a " <>
            "hub filters on, and a group without one belongs to no story (STR-68)"
  end

  def create(owner, %Group{} = group, opts),
    do: Library.put(%{owner: owner, kind: Group.kind(), payload: group}, opts)

  @doc "The group behind a library entry id, or nil if it isn't one."
  @spec get(term(), keyword()) :: Group.t() | nil
  def get(id, opts \\ []) do
    with entry when not is_nil(entry) <- Library.get(id, opts),
         %Group{} = group <- Library.payload(entry) do
      # Normalised here so every caller gets a complete struct. A payload written before
      # a field existed decodes without the key, and reading it as `group.campaign_id`
      # raises rather than answering nil — see `Group.load/1`.
      Group.load(group)
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

  @doc """
  Replace a group's authored fields, leaving its membership and its campaign alone.

  It takes the whole struct, so anything the caller didn't set is `nil` and would
  overwrite what is stored. Membership and hue have always been carried over from the
  record for that reason; **`campaign_id` is carried over for a stronger one** — it is
  the scope key, and a save that quietly cleared it would put the group on no hub at
  all, recreating one row at a time exactly the class STR-68 removed. A group cannot be
  moved between campaigns by saving it, which is right: that would be a different
  operation, and nothing in the design asks for one.
  """
  @spec update_fields(term(), Group.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_fields(group_id, %Group{} = fields, opts \\ []) do
    update(group_id, opts, fn group ->
      %Group{
        fields
        | member_ids: group.member_ids,
          hue: fields.hue || group.hue,
          campaign_id: group.campaign_id
      }
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
