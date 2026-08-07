defmodule Polyphony.Authoring.Knowledge do
  @moduledoc """
  Who knows what, resolved against the world **as it is right now**.

  Everything here was a function on `Audience` or `WorldBible`, and everything here
  reads: a group's membership lives in the database, so expanding one is a query. That
  is the whole reason it moved. Those two modules are now what they look like — a struct
  and its pure helpers — and this module is the one place where "who knows this" stops
  being a shape and becomes an answer.

  **Resolution is live, and that is the feature.** A character written into the Tidewatch
  in scene 9 gets the Tidewatch's secrets from the moment they turn up, without anybody
  editing the secret. Storing the expansion would freeze it at writing time and make a
  group a list of names, which is exactly what a group is not.

  The function names did not change, only where they live: `resolve/2`, `knows?/3`,
  `known_by/3`, `known_to/3` and `for_character/3` read the same at every call site.
  """
  alias Polyphony.Authoring.{Audience, WorldBible}
  alias Polyphony.Groups

  @doc """
  Who this audience means **right now** — named characters plus every current member
  of every named group, de-duplicated, named-first.

  Resolved rather than stored, because a group's membership will change and the whole
  point of naming one is that the audience moves with it.

  `opts[:owner]` is the character the secret is *about*: a character always knows
  their own secrets, so they are included whether or not anyone ticked them.
  `opts[:repo]` is passed through to `Polyphony.Groups`.
  """
  @spec resolve(Audience.t() | nil, keyword()) :: [String.t()]
  def resolve(audience, opts \\ [])
  def resolve(nil, opts), do: owner_list(opts)

  def resolve(%Audience{} = a, opts) do
    from_groups = Enum.flat_map(a.group_ids, &Groups.member_ids(&1, repo_opts(opts)))
    from_scene = if a.scene, do: scene_members(opts), else: []

    (owner_list(opts) ++ a.character_ids ++ from_groups ++ from_scene) |> Enum.uniq()
  end

  defp scene_members(opts),
    do: opts |> Keyword.get(:scene_members, []) |> Enum.map(&to_string/1)

  @doc """
  Does `character_id` start out knowing this?

  The read every context assembly makes, and the reason resolution is live: it is
  asked when a character is being written into a scene, which is exactly when a
  newly-written group member should turn out to already know.
  """
  @spec knows?(Audience.t() | nil, term(), keyword()) :: boolean()
  def knows?(audience, character_id, opts \\ []) do
    to_string(character_id) in resolve(audience, opts)
  end

  @doc """
  The other direction: everything `character_id` starts out knowing, from every source
  they're an audience of.

  A **read-only projection**, and deliberately derived rather than stored — one fact,
  one home, so the two directions cannot drift out of sync. You can see it from a
  character's sheet; you edit it from the secret.

  `sources` is `[{owner_label, owner_id, items}]`, where `items` are anything carrying
  `statement`, `concealed` and `audience` — a character's facts, a world bible's
  entries. Returns `[%{statement:, from:, why:}]`, where `why` says how they came by
  it, because an inherited one should be obvious.
  """
  @spec known_by(term(), [{String.t(), term() | nil, [map()]}], keyword()) :: [map()]
  def known_by(character_id, sources, opts \\ []) do
    me = to_string(character_id)

    for {label, owner_id, items} <- sources,
        item <- items || [],
        Map.get(item, :concealed),
        owner_opts = if(owner_id, do: Keyword.put(opts, :owner, owner_id), else: opts),
        knows?(item.audience, me, owner_opts),
        do: %{
          statement: item.statement,
          from: label,
          why: why(item.audience, me, owner_id, owner_opts)
        }
  end

  defp why(_audience, me, owner_id, _opts) when not is_nil(owner_id) and me == owner_id,
    do: :own

  defp why(audience, me, _owner_id, opts) do
    audience = Audience.from(audience)

    cond do
      me in audience.character_ids -> :named
      Enum.any?(audience.group_ids, &(me in Groups.member_ids(&1, repo_opts(opts)))) -> :group
      true -> :named
    end
  end

  defp owner_list(opts) do
    case Keyword.get(opts, :owner) do
      nil -> []
      owner -> [to_string(owner)]
    end
  end

  defp repo_opts(opts), do: Keyword.take(opts, [:repo])

  @doc """
  What one character may read: the public statements, plus the concealed ones whose
  audience includes them.

  Resolution is live (`Audience.resolve/2` expands groups when asked), so a character
  written into the Tidewatch in scene 9 gets the Tidewatch's secrets from the moment
  they turn up — which is the whole reason a group is stored as a group.

  A nil `character_id` is a stranger: `public/1`, and nothing else.
  """
  @spec known_to([WorldBible.Entry.t() | String.t() | map()], term() | nil, keyword()) :: [
          String.t()
        ]
  def known_to(list, character_id, opts \\ [])
  def known_to(list, nil, _opts), do: WorldBible.public(list)

  def known_to(list, character_id, opts) do
    for e <- WorldBible.entries(list),
        not e.concealed or knows?(e.audience, character_id, opts),
        do: e.statement
  end

  @doc """
  The bible as one character may see it: concealed rules and canon removed unless
  their audience includes that character.

  Used for the character-facing context and for the read-only *preview as* on the
  editor (§3.2) — the same filter, so what an author previews is what a character
  actually gets. With no character (a stranger, or the un-assigned viewer §3.2 calls
  a real state) it is default-deny: every secret is gone.
  """
  @spec for_character(WorldBible.t(), term() | nil, keyword()) :: WorldBible.t()
  def for_character(bible, character_id \\ nil, opts \\ [])

  def for_character(%WorldBible{} = bible, character_id, opts) do
    %WorldBible{
      bible
      | rules: visible(bible.rules, character_id, opts),
        starting_canon: visible(bible.starting_canon, character_id, opts)
    }
  end

  defp visible(list, nil, _opts), do: Enum.reject(WorldBible.entries(list), & &1.concealed)

  defp visible(list, character_id, opts) do
    Enum.filter(
      WorldBible.entries(list),
      &(not &1.concealed or knows?(&1.audience, character_id, opts))
    )
  end
end
