defmodule Polyphony.Permissions do
  @moduledoc """
  Who may change what — the one place that answers it.

  ## What it fixes

  The authoring screens loaded a library entry by id and checked only that it existed
  and hadn't been moderated. Ownership was never asked. Ids are small integers, so any
  signed-in account could open `/authoring/bible/91` — or somebody else's campaign,
  character, group, or live scene — and write to it. `Owner` had been threaded through
  every *read* since §P2 and every screen scoped its lists correctly; nothing scoped the
  entry a URL named.

  ## The rule

  **You may edit what you own. Everything else you copy.** That is the design's own
  answer (§2.5b) and the reason `Library.copy/2` and `fork_campaign/3` exist: a world is
  a template, attaching one copies it, and a campaign accumulates a history that two
  people cannot both write. Editing somebody else's entry in place was never the
  intended affordance — it was reachable by accident.

  ## The seam for later

  Shared editing is coming and this is where it lands: `editors_of/1` is the whole
  extension point. Today it returns `[]` and edit access means ownership; when a
  campaign can have collaborators it returns their owners and **nothing else in the app
  changes**. That is why the check is `owner?/2 or editor?/2` rather than an equality
  test inlined at four mounts — an equality test at four mounts is four places to
  remember, and the fifth screen forgets.

  Deliberately *not* modelled yet: roles (editor vs. commenter), per-field grants,
  invitations. All of them are multiplayer features, and guessing at their shape now
  would bake assumptions into an authorization check, which is the worst place to keep
  a guess.

  ## Not `Polyphony.Access`

  Named `Permissions` because `Access` is an Elixir kernel module — `get_in/2` and
  `Access.key/1` are used in this codebase already — and a local alias shadowing it
  would work right up until someone in the aliasing file reached for the real one.

  ## Frozen entries

  A published snapshot is `frozen: true` and nobody edits it, its owner included —
  republishing replaces it (`Library.publish_campaign/2`). So `can_edit?/2` refuses one
  outright rather than treating it as an ownership question, because "the owner may
  edit their own things" would otherwise quietly make snapshots mutable.
  """

  alias Polyphony.Library
  alias Polyphony.Owner
  alias Polyphony.ReadModels.LibraryEntry

  @type actor :: Owner.t() | struct() | term() | nil

  @doc """
  May `actor` change this entry?

  Nil for either side is a no. A nil actor is a signed-out request, and a nil entry is
  one that doesn't exist or was moderated away — both of which the caller then reports
  as *not found*, because saying which would tell a stranger something true about
  somebody else's account.
  """
  @spec can_edit?(LibraryEntry.t() | nil, actor()) :: boolean()
  def can_edit?(nil, _actor), do: false
  def can_edit?(_entry, nil), do: false
  def can_edit?(%LibraryEntry{frozen: true}, _actor), do: false

  def can_edit?(%LibraryEntry{} = entry, actor) do
    cond do
      Library.hidden?(entry) -> false
      owner?(entry, actor) -> true
      true -> editor?(entry, actor)
    end
  end

  @doc "Does `actor` own this entry outright?"
  @spec owner?(LibraryEntry.t() | nil, actor()) :: boolean()
  def owner?(nil, _actor), do: false
  def owner?(_entry, nil), do: false

  def owner?(%LibraryEntry{owner_type: type, owner_id: id}, actor) do
    owner = Owner.coerce(actor)
    to_string(type) == Owner.type_string(owner) and to_string(id) == to_string(owner.id)
  end

  @doc """
  The owners who may edit this entry besides the one who owns it.

  **The multiplayer seam.** Empty today, and every caller already routes through
  `can_edit?/2`, so shared editing is a change to this function and a table to read
  from — not a sweep through the screens.
  """
  @spec editors_of(LibraryEntry.t() | nil) :: [Owner.t()]
  def editors_of(_entry), do: []

  @doc """
  May `actor` read this entry?

  Broader than editing on purpose: a published or shared entry is readable by anyone,
  which is what makes "this is somebody else's — take a copy" an honest thing to say
  rather than a hint that the id exists.
  """
  @spec can_view?(LibraryEntry.t() | nil, actor()) :: boolean()
  def can_view?(nil, _actor), do: false

  def can_view?(%LibraryEntry{} = entry, actor) do
    cond do
      Library.hidden?(entry) -> false
      entry.visibility in ["public", "unlisted"] -> true
      true -> can_edit?(entry, actor)
    end
  end

  @doc """
  May `actor` play this scene?

  A scene is not a library entry — it is an event stream — so its access is its
  **campaign's**: playing writes fiction into somebody's story, which is editing it by
  another name. `campaign_id` has been on `SceneOpened` since §2.3 and the campaign
  screen is the only thing in the app that opens a scene, so every scene a user can
  reach has one.

  A scene with **no** campaign is therefore not something the app produces. It is the
  domain layer being usable without the web layer — the property that lets the whole
  engine run and be tested offline — and those scenes are allowed here rather than
  denied, because denying them would be authorising on the absence of a field. If
  anything else ever opens a scene, this is the clause to revisit first; a test pins
  that the campaign screen always sets the id.
  """
  @spec can_play?(term(), actor(), keyword()) :: boolean()
  def can_play?(campaign_id, actor, opts \\ [])
  def can_play?(nil, _actor, _opts), do: true
  def can_play?("", _actor, _opts), do: true

  def can_play?(campaign_id, actor, opts) do
    case Library.get(campaign_id, opts) do
      # A campaign that has been deleted outright leaves its scenes readable to whoever
      # was already in them; there is nothing left to check against.
      nil -> true
      entry -> owner?(entry, actor) or editor?(entry, actor)
    end
  end

  defp editor?(entry, actor) do
    owner = Owner.coerce(actor)

    Enum.any?(
      editors_of(entry),
      &(&1.type == owner.type and to_string(&1.id) == to_string(owner.id))
    )
  end
end
