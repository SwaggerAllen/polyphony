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

  The **library shelf's** read: it shows everything the author has, banded by campaign,
  including the ones belonging to no campaign. A campaign hub wants `list_for_campaign/3`
  instead.
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

  A group with no campaign appears here for **nobody**, deliberately: it is not this
  campaign's, and putting it on every hub is the bug this replaces. `orphans/2` is where
  it stays reachable.
  """
  @spec list_for_campaign(term(), term(), keyword()) :: [map()]
  def list_for_campaign(owner, campaign_id, opts \\ [])
  def list_for_campaign(_owner, nil, _opts), do: []

  def list_for_campaign(owner, campaign_id, opts) do
    want = to_string(campaign_id)
    owner |> list(opts) |> Enum.filter(&(campaign_id_of(&1) == want))
  end

  @doc """
  The author's groups belonging to no campaign.

  Expected output of the backfill rather than a failure it should have resolved by
  guessing: a group written from the library against a template world has no campaign,
  and inventing one for it would be filing somebody's work under a story it isn't part
  of. They stay on the library shelf so they can be deleted — filtering them out of
  every hub *and* the shelf would leave rows nobody can reach.
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

  **A group that neither answers has no campaign, and that is the answer**, not a
  failure to try harder. Inventing one would file somebody's work under a story it was
  never part of, and `orphans/2` keeps it reachable.

  Owner is checked before assigning. Library ids come from one sequence so a cross-owner
  match shouldn't be possible, but "shouldn't be possible" is the wrong thing to rely on
  in the one pass that rewrites every row unattended.
  """
  @spec backfill_campaigns(keyword()) :: [%{id: term(), campaign_id: term() | nil}]
  def backfill_campaigns(opts \\ []) do
    campaigns = "campaign" |> Library.of_kind(opts) |> Enum.reject(&Library.snapshot?/1)
    by_bible = index(campaigns, &(Map.get(&1, :bible_id) |> List.wrap()))
    by_character = index(campaigns, &(Map.get(&1, :character_ids) || []))

    "group"
    |> Library.of_kind(opts)
    |> Enum.filter(&is_nil(campaign_id_of(&1)))
    |> Enum.flat_map(&assign_campaign(&1, by_bible, by_character, opts))
  end

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

  defp assign_campaign(entry, by_bible, by_character, opts) do
    case Library.payload(entry) do
      %Group{} = group ->
        group = Group.load(group)

        campaign =
          owned_by(by_bible[to_string(group.world_bible_id)], entry) ||
            Enum.find_value(group.member_ids || [], &owned_by(by_character[to_string(&1)], entry))

        write_campaign(entry, group, campaign, opts)

      other ->
        # Skipped rather than raised, and the asymmetry with
        # `Library.orphaned_characters/1` is deliberate: that one refuses to guess
        # because guessing deletes a campaign's cast, where the worst this can do is
        # leave one group on the library shelf as an orphan. Blocking a deploy over a
        # scope key would be the more expensive mistake. Logged so it isn't silent.
        Logger.warning("[groups] entry ##{entry.id} isn't a group payload: #{inspect(other)}")
        []
    end
  end

  defp write_campaign(_entry, _group, nil, _opts), do: []

  defp write_campaign(entry, group, campaign, opts) do
    {:ok, _} = Library.update_payload(entry.id, %Group{group | campaign_id: campaign.id}, opts)
    [%{id: entry.id, campaign_id: campaign.id}]
  end

  defp owned_by(nil, _entry), do: nil

  defp owned_by(campaign, entry) do
    if campaign.owner_type == entry.owner_type and
         to_string(campaign.owner_id) == to_string(entry.owner_id),
       do: campaign
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
