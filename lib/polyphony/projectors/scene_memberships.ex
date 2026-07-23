defmodule Polyphony.Projectors.SceneMemberships do
  @moduledoc """
  Projects `CharacterEntered`/`CharacterExited` into the `scene_memberships`
  interval read model (§8).

  A thin Commanded wrapper: the actual writes and queries live in
  `Polyphony.ReadModels.Membership`, so the SQL exercised by the test suite is
  the SQL that runs here. `member_at_fun/0` hands `Polyphony.Visibility` the
  same `(scene_id, char_id, beat) -> boolean` closure the pure `MembershipSet`
  exposes, so the visibility predicate is oblivious to which side answers.
  """
  use Commanded.Projections.Ecto,
    application: Polyphony.App,
    repo: Polyphony.Repo,
    name: "scene_memberships"

  alias Polyphony.Events.{CharacterEntered, CharacterExited}
  alias Polyphony.ReadModels.Membership
  alias Polyphony.Repo

  project(%CharacterEntered{} = e, _metadata, fn multi ->
    Ecto.Multi.run(multi, :enter, fn repo, _ ->
      {:ok, Membership.enter(repo, e.scene_id, e.character_id, e.beat)}
    end)
  end)

  project(%CharacterExited{} = e, _metadata, fn multi ->
    Ecto.Multi.run(multi, :leave, fn repo, _ ->
      {:ok, Membership.leave(repo, e.scene_id, e.character_id, e.beat)}
    end)
  end)

  @doc "Is `character_id` a member of `scene_id` at `beat`? (Postgres-backed.)"
  @spec member_at?(term(), term(), integer()) :: boolean()
  def member_at?(scene_id, character_id, beat),
    do: Membership.member_at?(Repo, scene_id, character_id, beat)

  @doc "Character ids present at `scene_id` at `beat`."
  @spec members_at(term(), integer()) :: [String.t()]
  def members_at(scene_id, beat), do: Membership.members_at(Repo, scene_id, beat)

  @doc "A `member_at?/3` closure for `Polyphony.Visibility`, backed by Postgres."
  @spec member_at_fun() :: (term(), term(), integer() -> boolean())
  def member_at_fun, do: &member_at?/3
end
