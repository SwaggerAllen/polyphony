defmodule Polyphony.Branching do
  @moduledoc """
  Branches as an author-facing thing (STR-8): the direct surface over `Fork.fork/3`.

  `Fork.fork/3` is the domain primitive — copy-on-fork onto a new scene stream —
  and for a long time it was reachable only through an edit that claimed to have
  changed what happened. This module is the missing surface: asking for a branch
  directly, without the pretence, plus everything a campaign full of branches
  needs to stay navigable.

  ## Vocabulary, and it is load-bearing

  A **branch** is a second line *inside your own campaign*: it appears in the
  branch navigator, and only the canonical one publishes. A **fork** is somebody
  taking a published story into their own library, where it becomes a campaign of
  their own. Both are `Fork.fork/3` underneath, which is exactly why the product
  keeps them apart in language — one word doing two jobs is what made *only
  canonical publishes* look like it needed an exception, when it never did.

  ## The shape of the data

  * The tree is **keyed on branches, not on scenes**: lineage is `parent_id` and
    `cut_beat`; `origin_scene_id` is a label. A deleted scene never strands its
    children.
  * The **root line** is created lazily the first time a campaign branches, and it
    claims no scenes — a scene no branch claims belongs to the root, so a
    never-branched campaign carries no bookkeeping at all.
  * **Canonical** is one per campaign: what the hub opens on, what publishing
    points at, what a party follows. It can be neither archived nor deleted — set
    another line canonical first — which is also what guarantees the tombstone
    walk terminates.
  * The **cut** is where a line started diverging and never moves. The **cursor**
    is where it diverges *now*: it moves on any change earlier than its current
    position, and it only moves earlier.
  * **Delete re-parents; it does not cascade.** Children move up under the
    grandparent and keep everything they copied (they were never dependent on the
    parent — they copied everything at the cut). Recursive deletion is an explicit
    opt-in. Every deletion leaves a tombstone — the line's id, its parent, the cut
    beat — so links into the deleted line resolve to the nearest surviving
    ancestor instead of a 404.

  Names default to *scene · location · beat*, describing the cut because the
  content does not exist yet, with an ordinal appended only on collision.
  """

  alias Polyphony.{Campaigns, Fork, Library}
  alias Polyphony.Authoring.Effective
  alias Polyphony.ReadModels.{Branch, BranchTombstone}
  alias Polyphony.Repo

  # ── Branching from here ──────────────────────────────────────────────────────

  @doc """
  Branch `parent_scene_id` at `through_beat`, directly — the bare "branch from
  here". Copies the stream through the cut (`Fork.fork/3`), records the line in
  the campaign's tree, and adopts the new scene into the campaign so both lines
  stay playable.

  Opts: `:location` (the authored scene location, used for the default name),
  `:name` (override the default entirely), plus `Fork`'s `:new_scene_id`.

  Returns `{:ok, %{branch:, scene_id:}}`.
  """
  @spec branch_from(term(), term(), integer(), keyword()) ::
          {:ok, %{branch: Branch.t() | struct(), scene_id: term()}} | {:error, term()}
  def branch_from(campaign_id, parent_scene_id, through_beat, opts \\ []) do
    # Copies first: the fork has to re-point the prefix's character references at
    # the copies, so the map must exist before the stream does. A fork that fails
    # after this leaves orphaned copies in the library — recoverable clutter,
    # where the reverse order would be a branch whose transcript speaks as the
    # *original* cast and feeds their arc queue.
    copies = prepare_line(campaign_id, parent_scene_id, opts)

    with {:ok, new_scene_id} <-
           Fork.fork(
             parent_scene_id,
             through_beat,
             Keyword.take(opts, [:new_scene_id]) ++
               [
                 label: opts[:name] || "branched at beat #{through_beat}",
                 character_map: copies.character_map
               ]
           ) do
      branch =
        register_fork(
          campaign_id,
          parent_scene_id,
          new_scene_id,
          through_beat,
          Keyword.put(opts, :copies, copies)
        )

      {:ok, %{branch: branch, scene_id: new_scene_id}}
    end
  end

  @doc """
  Copy-on-branch, the copying half: duplicate the line's cast and world into new
  library entries and return `%{character_map:, character_ids:, bible_id:}`.

  Each character copy's base sheet is the **effective** sheet at the cut — the
  authored sheet with its accepted arc folded in — because the branch copies
  everything *up to* the cut and shares nothing after: the two Wrens agree about
  the past and are free to disagree from here. Pending proposals stay with the
  original line; they were raised by its scenes.

  Called separately by the edit path, which needs the map before `Edit.edit/6`
  forks the stream.
  """
  def prepare_line(campaign_id, parent_scene_id, opts \\ []) do
    source = line_of(campaign_id, parent_scene_id, opts)

    {char_ids, bible_id, owner} = line_assets(campaign_id, source, opts)

    pairs =
      for old_id <- char_ids,
          entry = Library.get(old_id, opts),
          entry != nil do
        sheet = Library.payload(entry)

        copy =
          Library.put(
            %{owner: owner, kind: "character", payload: Effective.sheet(sheet, entry.id)},
            opts
          )

        {to_string(old_id), to_string(copy.id)}
      end

    bible_copy =
      with id when not is_nil(id) <- bible_id,
           entry when not is_nil(entry) <- Library.get(id, opts) do
        Library.put(%{owner: owner, kind: "world_bible", payload: Library.payload(entry)}, opts)
      else
        _ -> nil
      end

    %{
      character_map: Map.new(pairs),
      character_ids: Enum.map(pairs, &elem(&1, 1)),
      bible_id: bible_copy && to_string(bible_copy.id)
    }
  end

  # What the line being branched *from* holds: the parent branch's own copies, or
  # the campaign payload for the root line.
  defp line_assets(campaign_id, source, opts) do
    entry = Library.get(campaign_id, opts)
    payload = (entry && Library.payload(entry)) || %{}

    owner =
      entry &&
        %Polyphony.Owner{
          type: String.to_existing_atom(entry.owner_type),
          id: to_string(entry.owner_id)
        }

    case source do
      %Branch{parent_id: parent, character_ids: ids, bible_id: bid}
      when not is_nil(parent) and ids != [] ->
        {ids, bid, owner}

      _root_or_nil ->
        {Enum.map(List.wrap(Map.get(payload, :character_ids)), &to_string/1),
         Map.get(payload, :bible_id), owner}
    end
  end

  @doc """
  Record an already-forked stream as a line in the campaign's tree, and adopt the
  new scene into the campaign's scenes list.

  `branch_from/4` goes through here, and so should the edit path (`Edit.edit/6`
  with `:invalid`), which forks the stream itself — a branch made by an edit is a
  branch, and a tree that can't see it would misrepresent the campaign.
  """
  def register_fork(campaign_id, parent_scene_id, new_scene_id, through_beat, opts \\ []) do
    repo = repo(opts)
    cid = to_string(campaign_id)

    root = ensure_root(cid, opts)
    parent = Branch.of_scene(repo, cid, parent_scene_id) || root
    copies = opts[:copies] || %{character_ids: [], bible_id: nil}

    name =
      opts[:name] ||
        default_name(cid, opts[:location] || "A scene", through_beat, opts)

    branch =
      repo.insert!(%Branch{
        campaign_id: cid,
        parent_id: parent.id,
        origin_scene_id: to_string(parent_scene_id),
        cut_beat: through_beat,
        name: name,
        canonical: false,
        scene_ids: [to_string(new_scene_id)],
        # Copy-on-branch: the line's own cast and world, copied at the cut — and
        # who is who across it, so a reader's granted head survives a line switch.
        character_ids: copies.character_ids,
        bible_id: copies.bible_id,
        parent_map: Map.get(copies, :character_map, %{}),
        # A fresh branch diverges exactly at its cut — the cursor starts there and
        # only ever moves earlier.
        cursor_scene_id: to_string(new_scene_id),
        cursor_beat: through_beat
      })

    adopt_scene(cid, new_scene_id, opts)
    branch
  end

  # The root line, created lazily the first time a campaign branches. Canonical by
  # default: until somebody says otherwise, the line everybody is in is the one
  # that has always existed.
  defp ensure_root(campaign_id, opts) do
    repo = repo(opts)

    case Enum.find(Branch.list_for_campaign(repo, campaign_id), &is_nil(&1.parent_id)) do
      %Branch{} = root ->
        root

      nil ->
        repo.insert!(%Branch{
          campaign_id: campaign_id,
          parent_id: nil,
          name: root_name(campaign_id, opts),
          canonical: true,
          scene_ids: []
        })
    end
  end

  defp root_name(campaign_id, opts) do
    case Library.get(campaign_id, opts) do
      nil -> "The original"
      entry -> Campaigns.name(entry)
    end
  end

  # *scene · location · beat*, with an ordinal appended only on collision — the
  # common case stays clean. The default describes the cut, not the content,
  # because the content does not exist yet: its job is a stable handle the author
  # can overwrite once they know what the line is for.
  defp default_name(campaign_id, location, through_beat, opts) do
    base = "#{location} · beat #{through_beat}"
    taken = repo(opts) |> Branch.list_for_campaign(campaign_id) |> MapSet.new(& &1.name)

    if MapSet.member?(taken, base) do
      Enum.find_value(2..1000, fn n ->
        candidate = "#{base} (#{n})"
        if not MapSet.member?(taken, candidate), do: candidate
      end)
    else
      base
    end
  end

  # The campaign has to name the new stream or nothing can reach it: the scenes
  # list, deletion, publishing and the reader all walk `payload.scenes`.
  defp adopt_scene(campaign_id, scene_id, opts) do
    case Library.get(campaign_id, opts) do
      nil ->
        :ok

      entry ->
        payload = Library.payload(entry) || %{}
        scenes = Enum.map(List.wrap(Map.get(payload, :scenes)), &to_string/1)
        sid = to_string(scene_id)

        if sid in scenes do
          :ok
        else
          {:ok, _} =
            Library.update_payload(entry.id, Map.put(payload, :scenes, scenes ++ [sid]), opts)

          :ok
        end
    end
  end

  @doc """
  Claim a scene for a line — called when a scene opens while the author is
  working in a branch. Unclaimed scenes belong to the root, so a never-branched
  campaign never calls this.
  """
  def claim_scene(branch_id, scene_id, opts \\ []) do
    repo = repo(opts)

    case Branch.get(repo, branch_id) do
      # The root claims nothing; anything unclaimed is already its.
      nil -> :ok
      %Branch{parent_id: nil} -> :ok
      %Branch{} = b -> claim(repo, b, scene_id)
    end
  end

  defp claim(repo, branch, scene_id) do
    sid = to_string(scene_id)

    if sid in branch.scene_ids do
      :ok
    else
      branch |> Ecto.Changeset.change(scene_ids: branch.scene_ids ++ [sid]) |> repo.update!()
      :ok
    end
  end

  # ── Reading the tree ─────────────────────────────────────────────────────────

  @doc "Has this campaign ever branched? The pill and the selector hang on this."
  def branched?(campaign_id, opts \\ []),
    do: Branch.list_for_campaign(repo(opts), to_string(campaign_id)) != []

  @doc "The canonical line — what publishes — or nil when the campaign never branched."
  def canonical_line(campaign_id, opts \\ []),
    do: Branch.canonical(repo(opts), to_string(campaign_id))

  @doc """
  The campaign's tree, depth-first: `[%{branch:, depth:}]`, archived lines
  excluded unless `include_archived: true`. Empty when the campaign has never
  branched — a campaign with one line is a campaign, not a tree of one.
  """
  def tree(campaign_id, opts \\ []) do
    rows = Branch.list_for_campaign(repo(opts), to_string(campaign_id))

    rows =
      if opts[:include_archived],
        do: rows,
        else: Enum.filter(rows, &is_nil(&1.archived_at))

    by_parent = Enum.group_by(rows, & &1.parent_id)

    by_parent
    |> Map.get(nil, [])
    |> Enum.flat_map(&walk(&1, 0, by_parent))
  end

  defp walk(branch, depth, by_parent) do
    children = Map.get(by_parent, branch.id, [])
    [%{branch: branch, depth: depth} | Enum.flat_map(children, &walk(&1, depth + 1, by_parent))]
  end

  @doc """
  The line a scene belongs to: its claiming branch, or the root row (nil when the
  campaign has never branched).
  """
  def line_of(campaign_id, scene_id, opts \\ []) do
    repo = repo(opts)
    cid = to_string(campaign_id)

    Branch.of_scene(repo, cid, scene_id) ||
      Enum.find(Branch.list_for_campaign(repo, cid), &is_nil(&1.parent_id))
  end

  @doc """
  This line's scenes, in story order — what the hub's scenes list and a reader's
  contents mean once a second branch exists.

  A line's story is **the shared past plus its own scenes**: everything its
  ancestors played *before* the scene it was cut in (that scene itself came
  across as the branch's own copy, so it is not repeated), then what the line
  played since. Two lines are separate stories that happen to remember the same
  past, and the remembering is literal — the prefix scenes are the same rows.

  `branch` may be a `%Branch{}` or nil/root, where the answer is every scene no
  branch has claimed.
  """
  def scenes_for(campaign_id, branch, opts \\ []) do
    repo = repo(opts)
    cid = to_string(campaign_id)
    payload_scenes = payload_scenes(cid, opts)
    rows = Branch.list_for_campaign(repo, cid)
    line_scenes(branch, payload_scenes, Map.new(rows, &{&1.id, &1}))
  end

  defp payload_scenes(cid, opts) do
    case Library.get(cid, opts) do
      nil ->
        []

      entry ->
        (Library.payload(entry) || %{})
        |> Map.get(:scenes)
        |> List.wrap()
        |> Enum.map(&to_string/1)
    end
  end

  defp line_scenes(%Branch{parent_id: parent} = b, payload_scenes, by_id)
       when not is_nil(parent) do
    own = Enum.filter(payload_scenes, &(&1 in b.scene_ids))

    prefix =
      case Map.get(by_id, parent) do
        nil ->
          []

        parent_row ->
          parent_list = line_scenes(parent_row, payload_scenes, by_id)

          case Enum.find_index(parent_list, &(&1 == b.origin_scene_id)) do
            # The origin scene is gone from the parent: the anchor for "before the
            # cut" went with it, so the shared past can't be reconstructed here.
            # The line keeps its own scenes — which are the ones it can vouch for.
            nil -> []
            idx -> Enum.take(parent_list, idx)
          end
      end

    prefix ++ own
  end

  defp line_scenes(_root_or_nil, payload_scenes, by_id) do
    claimed =
      for {_id, b} <- by_id,
          not is_nil(b.parent_id),
          s <- b.scene_ids,
          into: MapSet.new(),
          do: s

    Enum.reject(payload_scenes, &MapSet.member?(claimed, &1))
  end

  # ── Canonical ────────────────────────────────────────────────────────────────

  @doc """
  Point canonical at a line. One per campaign — what everybody else sees: the hub
  opens on it, publishing points at it, and once a group plays together the party
  follows it. An authority claim about a session, not a verdict on the fiction.
  """
  def set_canonical(branch_id, opts \\ []) do
    repo = repo(opts)

    case Branch.get(repo, branch_id) do
      nil ->
        {:error, :not_found}

      %Branch{} = b ->
        repo.transaction(fn ->
          import Ecto.Query

          from(x in Branch, where: x.campaign_id == ^b.campaign_id and x.canonical)
          |> repo.update_all(set: [canonical: false])

          b |> Ecto.Changeset.change(canonical: true, archived_at: nil) |> repo.update!()
        end)

        :ok
    end
  end

  @doc "Rename a line. The default was a handle, not a description."
  def rename(branch_id, name, opts \\ []) do
    repo = repo(opts)
    name = String.trim(to_string(name))

    case {Branch.get(repo, branch_id), name} do
      {nil, _} -> {:error, :not_found}
      {_, ""} -> {:error, :empty_name}
      {b, _} -> b |> Ecto.Changeset.change(name: name) |> repo.update!() && :ok
    end
  end

  # ── Archive and delete ───────────────────────────────────────────────────────

  @doc """
  Archive a line: it leaves the selector and the tree's default view, keeps
  everything, and can come back. Most lines somebody wants rid of want this.
  Canonical refuses — set another line canonical first.
  """
  def archive(branch_id, opts \\ []) do
    repo = repo(opts)

    case Branch.get(repo, branch_id) do
      nil ->
        {:error, :not_found}

      %Branch{canonical: true} ->
        {:error, :canonical}

      %Branch{} = b ->
        b
        |> Ecto.Changeset.change(archived_at: NaiveDateTime.utc_now(:microsecond))
        |> repo.update!()

        :ok
    end
  end

  @doc "Bring an archived line back."
  def unarchive(branch_id, opts \\ []) do
    repo = repo(opts)

    case Branch.get(repo, branch_id) do
      nil -> {:error, :not_found}
      %Branch{} = b -> b |> Ecto.Changeset.change(archived_at: nil) |> repo.update!() && :ok
    end
  end

  @doc """
  Delete a line: its scenes go (through `Campaigns.delete_scene/3`, which also
  takes everything derived from them), its copies of the cast and world go with
  the scenes, and a tombstone survives so links keep answering.

  **Children are re-parented to the grandparent by default** and keep everything
  they copied — a recursive delete makes cleaning up all-or-nothing, which is how
  people end up never doing it. `recursive: true` deletes the whole subtree, each
  line leaving its own tombstone.

  Canonical refuses, which is also what guarantees the tombstone walk terminates.

  Returns `{:ok, %{deleted: n, reparented: k}}`.
  """
  def delete(branch_id, opts \\ []) do
    repo = repo(opts)

    case Branch.get(repo, branch_id) do
      nil ->
        {:error, :not_found}

      %Branch{canonical: true} ->
        {:error, :canonical}

      # The root line means "everything no branch claimed" — deleting it would be
      # deleting the campaign, which is the campaign screen's own three-endings
      # job, not the navigator's.
      %Branch{parent_id: nil} ->
        {:error, :root}

      %Branch{} = b ->
        if opts[:recursive] do
          {:ok, %{deleted: delete_subtree(b, opts), reparented: 0}}
        else
          import Ecto.Query

          {reparented, _} =
            from(x in Branch, where: x.parent_id == ^b.id)
            |> repo.update_all(set: [parent_id: b.parent_id])

          delete_one(b, opts)
          {:ok, %{deleted: 1, reparented: reparented}}
        end
    end
  end

  # Deepest first, so every line's own tombstone records the parent it actually
  # had — the walk up from any of them lands on the survivor above the subtree.
  defp delete_subtree(branch, opts) do
    repo = repo(opts)

    beneath =
      repo
      |> Branch.children(branch.id)
      |> Enum.map(&delete_subtree(&1, opts))
      |> Enum.sum()

    delete_one(branch, opts)
    beneath + 1
  end

  defp delete_one(branch, opts) do
    repo = repo(opts)

    # The record that keeps circulating links answerable: the line's id, its
    # parent, the beat it was cut at, and the scenes it held — the last is what
    # lets a link naming one of its scenes find this at all. Written before the
    # row goes, so a crash between the two errs on the side of the link resolving.
    BranchTombstone.put(repo, %{
      branch_id: branch.id,
      campaign_id: branch.campaign_id,
      parent_id: branch.parent_id,
      cut_beat: branch.cut_beat,
      origin_scene_id: branch.origin_scene_id,
      scene_ids: branch.scene_ids
    })

    Enum.each(branch.scene_ids, fn scene_id ->
      _ = Campaigns.delete_scene(branch.campaign_id, scene_id, opts)
    end)

    # Its copies of the cast and world go with it — to the trash, like everything
    # else the library lets go of, so the countdown applies rather than the axe.
    for id <- branch.character_ids ++ List.wrap(branch.bible_id) do
      _ = Library.soft_delete(id, opts)
    end

    repo.delete!(branch)
    :ok
  end

  @doc """
  Answer a link into a line that may be gone: `{:ok, branch}` when it survives,
  `{:moved, ancestor, cut_beat}` when the walk lands on the nearest surviving
  ancestor at the deleted line's cut, `:error` when nothing answers.

  The walk always terminates because canonical can be neither deleted nor
  archived — see `campaign.md`.
  """
  def resolve(branch_id, opts \\ []) do
    repo = repo(opts)

    case Branch.get(repo, branch_id) do
      %Branch{} = b -> {:ok, b}
      nil -> walk_tombstones(branch_id, nil, opts)
    end
  end

  defp walk_tombstones(branch_id, cut, opts) do
    repo = repo(opts)

    case BranchTombstone.get(repo, branch_id) do
      nil ->
        :error

      t ->
        # The cut that matters is the *first* deleted line's — the last content the
        # link promised that still exists somewhere up the tree.
        cut = cut || t.cut_beat

        case t.parent_id && Branch.get(repo, t.parent_id) do
          %Branch{} = parent -> {:moved, parent, cut}
          _ -> if t.parent_id, do: walk_tombstones(t.parent_id, cut, opts), else: :error
        end
    end
  end

  @doc """
  Answer a link that names a **scene** of a line that may be gone: `{:ok, line}`
  when a live line holds it, `{:moved, ancestor, landing_scene_id}` when only a
  tombstone remembers it — the reader lands on the nearest surviving ancestor, at
  the deleted line's origin if it survives, else at the ancestor's own earliest
  change, else its first scene. `:error` when nothing here ever held that scene.
  """
  def resolve_scene(campaign_id, scene_id, opts \\ []) do
    repo = repo(opts)
    cid = to_string(campaign_id)

    case Branch.of_scene(repo, cid, scene_id) do
      %Branch{} = line ->
        {:ok, line}

      nil ->
        case BranchTombstone.of_scene(repo, cid, scene_id) do
          nil ->
            :error

          t ->
            case walk_tombstones(t.branch_id, t.cut_beat, opts) do
              :error -> :error
              {:moved, ancestor, _cut} -> {:moved, ancestor, landing(cid, ancestor, t, opts)}
            end
        end
    end
  end

  # The last content the link promised that still exists: the deleted line's
  # origin scene if the surviving ancestor still tells it, else the ancestor's
  # own earliest change, else the top of its story.
  defp landing(campaign_id, ancestor, tombstone, opts) do
    scenes = scenes_for(campaign_id, ancestor, opts)

    cond do
      tombstone.origin_scene_id in scenes -> tombstone.origin_scene_id
      ancestor.cursor_scene_id in scenes -> ancestor.cursor_scene_id
      true -> List.first(scenes)
    end
  end

  # ── The divergence cursor ────────────────────────────────────────────────────

  @doc """
  Notice that something changed at `{scene_id, beat}` on whatever line owns that
  scene. The cursor moves on any change earlier than its current position — a
  simple rule with no exceptions to remember — and it only ever moves earlier.

  The cut point is where a line *started* diverging and never moves; this is
  where it diverges *now*. One value per line, not per reader: a reading position
  is already a URL, so the cursor's only job is computing where the off-canon
  switch lands somebody.
  """
  def notice_change(campaign_id, scene_id, beat, opts \\ []) do
    repo = repo(opts)
    cid = to_string(campaign_id)
    rows = Branch.list_for_campaign(repo, cid)
    payload_scenes = payload_scenes(cid, opts)
    by_id = Map.new(rows, &{&1.id, &1})

    # A shared-past scene sits on more than one line — a change to it moves every
    # cursor it is earlier than, not just its claiming line's. A campaign that has
    # never branched has no rows and no divergence to track.
    for line <- rows do
      order = line_scenes(line, payload_scenes, by_id)
      new_pos = position(order, scene_id, beat)
      cur_pos = position(order, line.cursor_scene_id, line.cursor_beat)

      if new_pos != nil and (cur_pos == nil or new_pos < cur_pos) do
        line
        |> Ecto.Changeset.change(
          cursor_scene_id: to_string(scene_id),
          cursor_beat: beat || 0
        )
        |> repo.update!()
      end
    end

    :ok
  end

  @doc "Where a line diverges now: `{scene_id, beat}` or nil."
  def cursor(%Branch{cursor_scene_id: nil}), do: nil
  def cursor(%Branch{cursor_scene_id: s, cursor_beat: b}), do: {s, b || 0}

  # ── Who is who across lines ──────────────────────────────────────────────────

  @doc """
  Translate character ids from one line to another: `%{from_id => to_id}` for
  `ids`, walking each id up `from_line`'s cuts (inverse `parent_map`) to the
  deepest common ancestor and back down `to_line`'s. Copy-on-branch means the
  same person is a different library id on every line; this is what lets a
  reader's granted head survive a line switch, and it composes across nested
  cuts. Ids a map doesn't know pass through unchanged — an edit-fork made before
  copies existed still answers, identically.
  """
  def head_map(campaign_id, from_line, to_line, ids, opts \\ []) do
    rows = Branch.list_for_campaign(repo(opts), to_string(campaign_id))
    by_id = Map.new(rows, &{&1.id, &1})
    from_path = chain(from_line, by_id)
    to_path = chain(to_line, by_id)
    to_ids = MapSet.new(to_path, & &1.id)

    case Enum.find(from_path, &MapSet.member?(to_ids, &1.id)) do
      nil ->
        %{}

      ancestor ->
        lift = Enum.take_while(from_path, &(&1.id != ancestor.id))
        descend = to_path |> Enum.take_while(&(&1.id != ancestor.id)) |> Enum.reverse()

        for id <- ids, into: %{} do
          up = Enum.reduce(lift, to_string(id), &uncopy(&1.parent_map, &2))
          down = Enum.reduce(descend, up, &Map.get(&1.parent_map || %{}, &2, &2))
          {to_string(id), down}
        end
    end
  end

  # A line, then its parents up to the root. Nil (a never-branched campaign)
  # has no chain to speak of.
  defp chain(nil, _by_id), do: []

  defp chain(row, by_id) do
    case row.parent_id && Map.get(by_id, row.parent_id) do
      nil -> [row]
      parent -> [row | chain(parent, by_id)]
    end
  end

  # The inverse step: this line's copy back to its parent's original.
  defp uncopy(map, id),
    do: Enum.find_value(map || %{}, id, fn {parent_id, own_id} -> own_id == id && parent_id end)

  defp position(_order, nil, _beat), do: nil

  # A scene the line no longer holds has no position — callers deleting a scene
  # notice the change *before* the delete, while the position is still real.
  defp position(order, scene_id, beat) do
    case Enum.find_index(order, &(&1 == to_string(scene_id))) do
      nil -> nil
      idx -> {idx, beat || 0}
    end
  end

  defp repo(opts), do: Keyword.get(opts, :repo, Repo)
end
