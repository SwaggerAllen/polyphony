defmodule Polyphony.Permissions do
  @moduledoc """
  Who may see and change what — the one place that answers it.

  ## Why it says "the one place" twice

  It didn't used to be. `Polyphony.Library.Access` answered the same question in its own
  words — fully written, fully tested, and called by **nothing in `lib/`** — while the
  screen that actually decided whether a stranger could open a story
  (`Screens.Browse.published?/1`) answered it a third way, in a presentation module.

  Two of those three said an `unlisted` entry was readable by anyone; the deleted one
  was the only one that checked the share token, and it was the one nobody called. So a
  reader could open an unlisted story by guessing its id, and ids here are small
  integers. That is what four answers to one question costs, and it is why this module
  now holds reading as well as writing: a second implementation of an authorization rule
  is not redundancy, it is a rule that is enforced in some places and not others.

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
    not Library.hidden?(entry) and theirs?(entry, actor)
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

  Broader than editing on purpose: a published entry is readable by anyone, which is
  what makes "this is somebody else's — take a copy" an honest thing to say rather than
  a hint that the id exists.

  **`unlisted` is not a weaker `public`.** It means *reachable by the link and not
  otherwise*, so it needs the link: pass `token: t` and it is compared against the
  entry's `share_token`. Without one, an unlisted entry is readable only by its owner —
  the same answer a private one gives, which is the point, because an unlisted entry
  that answers differently from a private one to a stranger has told them it exists.

  Reading does not go through `can_edit?/2`, and the difference is `frozen`: a published
  snapshot refuses every edit including its author's, and routing reads through the edit
  check would have made an author unable to open their own unlisted publication. Frozen
  stops writing, not reading.
  """
  @spec can_view?(LibraryEntry.t() | nil, actor(), keyword()) :: boolean()
  def can_view?(entry, actor, opts \\ [])
  def can_view?(nil, _actor, _opts), do: false

  def can_view?(%LibraryEntry{} = entry, actor, opts) do
    cond do
      Library.hidden?(entry) -> false
      entry.visibility == "public" -> true
      entry.visibility == "unlisted" -> holds_link?(entry, opts[:token]) or theirs?(entry, actor)
      true -> theirs?(entry, actor)
    end
  end

  # Both halves must be present and equal. A nil `share_token` on the entry is an
  # unlisted entry that was never given a link, and a nil presented token is a reader
  # who doesn't hold one — neither is a match, and `nil == nil` would make them one.
  defp holds_link?(%LibraryEntry{share_token: token}, presented) do
    not is_nil(token) and not is_nil(presented) and to_string(token) == to_string(presented)
  end

  # Nil is a signed-out request and belongs to nobody. The clause is here rather than at
  # each entry point because `can_view?/3` and `can_edit?/2` both reach it, and `editor?`
  # coerces the actor — a nil that gets that far raises rather than denying, which is the
  # loudest possible way to fail a check that should quietly say no.
  defp theirs?(_entry, nil), do: false
  defp theirs?(entry, actor), do: owner?(entry, actor) or editor?(entry, actor)

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
      entry -> theirs?(entry, actor)
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
