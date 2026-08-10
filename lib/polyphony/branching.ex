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
    with {:ok, new_scene_id} <-
           Fork.fork(
             parent_scene_id,
             through_beat,
             Keyword.take(opts, [:new_scene_id]) ++
               [label: opts[:name] || "branched at beat #{through_beat}"]
           ) do
      branch = register_fork(campaign_id, parent_scene_id, new_scene_id, through_beat, opts)
      {:ok, %{branch: branch, scene_id: new_scene_id}}
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
  This line's scenes, in campaign order — what the hub's scenes list means once a
  second branch exists. `branch` may be a `%Branch{}` or nil/root, in which case
  the answer is every scene no branch has claimed.
  """
  def scenes_for(campaign_id, branch, opts \\ []) do
    repo = repo(opts)
    cid = to_string(campaign_id)

    payload_scenes =
      case Library.get(cid, opts) do
        nil ->
          []

        entry ->
          (Library.payload(entry) || %{})
          |> Map.get(:scenes)
          |> List.wrap()
          |> Enum.map(&to_string/1)
      end

    case branch do
      %Branch{parent_id: parent} = b when not is_nil(parent) ->
        Enum.filter(payload_scenes, &(&1 in b.scene_ids))

      _root_or_nil ->
        claimed =
          for b <- Branch.list_for_campaign(repo, cid),
              not is_nil(b.parent_id),
              s <- b.scene_ids,
              into: MapSet.new(),
              do: s

        Enum.reject(payload_scenes, &MapSet.member?(claimed, &1))
    end
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
    # parent, and the beat it was cut at. Written before the row goes, so a crash
    # between the two errs on the side of the link still resolving.
    BranchTombstone.put(repo, %{
      branch_id: branch.id,
      campaign_id: branch.campaign_id,
      parent_id: branch.parent_id,
      cut_beat: branch.cut_beat
    })

    Enum.each(branch.scene_ids, fn scene_id ->
      _ = Campaigns.delete_scene(branch.campaign_id, scene_id, opts)
    end)

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

    case line_of(campaign_id, scene_id, opts) do
      # A campaign that has never branched has no divergence to track.
      nil ->
        :ok

      %Branch{} = line ->
        order = scenes_for(campaign_id, line, opts)
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

        :ok
    end
  end

  @doc "Where a line diverges now: `{scene_id, beat}` or nil."
  def cursor(%Branch{cursor_scene_id: nil}), do: nil
  def cursor(%Branch{cursor_scene_id: s, cursor_beat: b}), do: {s, b || 0}

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
