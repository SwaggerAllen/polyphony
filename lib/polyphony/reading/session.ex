defmodule Polyphony.Reading.Session do
  @moduledoc """
  Reading a published campaign: a scene, from a chosen perspective (§3.1, §3.1b).

  The reason this screen exists at all — *no other reading app can offer the same scene
  from three heads.* Halden doesn't know what Ruthe already decided, and Ruthe doesn't
  hear what he says to the man on the stair. Neither version is marked up or annotated:
  each just reads as a scene, and the reader who switches finds out what they were
  missing.

  ## Everything here is a projection over a snapshot the caller already holds

  No reads. `Reading.scene/3` is the one that fetches a scene's events and filters them,
  and it lives on `Reading` because it goes to the event store — it used to be here, and
  it made a module of pure answers read as a query.

  There is no second implementation of visibility behind it either: `Publication.viewer/2`
  turns the reader's mode into a `PolyphonyCore.Visibility` viewer and `Visibility.project/3`
  does the rest, the same predicate that filters a character's context in play. That is
  the entire seam, deliberately — a reading view with its own idea of what a character
  knows is exactly how a preview ends up telling you something reassuring that isn't true.

  ## Two different kinds of empty, and they aren't interchangeable

    * **They weren't there.** A fact about the reader's current perspective, with a way
      out: switch, or carry on — *he found out about it the way you're about to,
      afterwards, from someone else.*
    * **Nobody's side was shared.** A fact about the publication, with no way out
      (§3.1c-ii). Shown rather than skipped, because silently dropping a scene would
      make the numbering lie and the story jump.
  """

  alias PolyphonyCore.Publication
  alias Polyphony.Library.Snapshot

  @doc """
  Why a scene came back empty — `nil` when it didn't.

    * `:not_shared` — no granted perspective could have shown it (§3.1c-ii).
    * `:not_present` — this reader's perspective wasn't there, but another could show
      it. The distinction is the whole difference between *switch, or carry on* and
      *you'll pick the story back up on the other side of it*.
  """
  @spec gap(Snapshot.t() | map(), map(), Publication.mode()) :: :not_shared | :not_present | nil
  def gap(snapshot, scene, mode) do
    pub = publication(snapshot)
    cast = Map.get(scene, :cast) || []

    cond do
      Publication.covers_scene?(pub, mode, cast) -> nil
      Enum.any?(Publication.modes(pub), &Publication.covers_scene?(pub, &1, cast)) -> :not_present
      true -> :not_shared
    end
  end

  @doc "The published scenes, oldest first — the contents list, and the numbering."
  @spec scenes(Snapshot.t() | map()) :: [map()]
  def scenes(snapshot), do: Map.get(snapshot, :scenes) || []

  @doc """
  The campaign's other lines at publish (STR-8): `%{id:, name:, parent_id:,
  cut_beat:, scenes: [...]}` each. Empty for a story that has only ever had one —
  which is almost always.
  """
  @spec lines(Snapshot.t() | map()) :: [map()]
  def lines(snapshot), do: Map.get(snapshot, :lines) || []

  @doc """
  The line a scene belongs to: `:canonical` when it is in the published contents,
  a line map when a non-canonical line holds it, `nil` when nothing here does.
  A reader has no branch to choose — this is what decides whether the off-canon
  pill has anything to say.
  """
  @spec line_for_scene(Snapshot.t() | map(), term()) :: :canonical | map() | nil
  def line_for_scene(snapshot, scene_id) do
    want = to_string(scene_id)

    cond do
      index_of(snapshot, want) != nil ->
        :canonical

      line = Enum.find(lines(snapshot), &line_holds?(&1, want)) ->
        line

      true ->
        nil
    end
  end

  defp line_holds?(line, scene_id),
    do: Enum.any?(Map.get(line, :scenes) || [], &(scene_id(&1) == scene_id))

  @doc """
  The last point a line and the published story share: the deepest scene their
  contents lists agree on. Everything before it is identical — the shared past is
  literal, the prefix scenes are the same rows — so there is no reason to make
  anybody read it twice. Nil when they share nothing that survived.
  """
  @spec shared_point(Snapshot.t() | map(), map()) :: map() | nil
  def shared_point(snapshot, line) do
    canonical = scenes(snapshot)
    other_ids = Enum.map(Map.get(line, :scenes) || [], &scene_id/1)

    canonical
    |> Enum.zip(other_ids)
    |> Enum.take_while(fn {canon_scene, other_id} -> scene_id(canon_scene) == other_id end)
    |> List.last()
    |> case do
      {scene, _} -> scene
      nil -> nil
    end
  end

  @doc """
  A scene's id, whichever shape the list is in.

  A published snapshot carries `%{id:, title:, cast:, beats:}` per scene; a campaign
  payload written before that carries bare ids. Both are real and neither is going to
  stop existing, so the shape question is answered **once, here**, rather than at every
  call site — where getting it wrong raises rather than returning a wrong answer, which
  is how a bookmark on a real published story crashes a shelf that tested fine against
  a list of strings.
  """
  @spec scene_id(map() | String.t()) :: String.t()
  def scene_id(%{} = scene), do: to_string(Map.get(scene, :id))
  def scene_id(id), do: to_string(id)

  @doc "The index of `scene_id` in `snapshot`, or nil if it isn't in it."
  @spec index_of(Snapshot.t() | map(), term()) :: non_neg_integer() | nil
  def index_of(snapshot, scene_id) do
    want = to_string(scene_id)
    Enum.find_index(scenes(snapshot), &(scene_id(&1) == want))
  end

  @doc "Where `scene_id` sits in the story, one-based, or nil if it isn't in it."
  @spec position(Snapshot.t() | map(), term()) :: {pos_integer(), pos_integer()} | nil
  def position(snapshot, scene_id) do
    case index_of(snapshot, scene_id) do
      nil -> nil
      i -> {i + 1, length(scenes(snapshot))}
    end
  end

  @doc "The scene after `scene_id`, or nil at the end."
  @spec next_scene(Snapshot.t() | map(), term()) :: map() | nil
  def next_scene(snapshot, scene_id) do
    all = scenes(snapshot)

    case index_of(snapshot, scene_id) do
      nil -> List.first(all)
      i -> Enum.at(all, i + 1)
    end
  end

  @doc """
  Display names for the published cast, by character id.

  The routing key is the id everywhere (§5.2); names are resolved at the edges, and
  this is the edge. Only the **pinned** sheets are consulted — never the author's live
  library — which is what makes a published story independent of a world that may since
  have been edited, privatized or deleted.
  """
  @spec names(Snapshot.t() | map()) :: %{String.t() => String.t()}
  def names(snapshot) do
    for c <- Map.get(snapshot, :characters) || [],
        id = Map.get(c, :source_id),
        into: %{} do
      {to_string(id), Map.get(Map.get(c, :sheet) || %{}, :name) || to_string(id)}
    end
  end

  @doc "The pinned sheet for a character id, or nil — only where `sheets?` allows it."
  @spec sheet(Snapshot.t() | map(), term()) :: map() | nil
  def sheet(snapshot, character_id) do
    if Publication.sheets?(publication(snapshot)) do
      snapshot
      |> Map.get(:characters)
      |> List.wrap()
      |> Enum.find_value(fn c ->
        if to_string(Map.get(c, :source_id)) == to_string(character_id),
          do: Map.get(c, :sheet)
      end)
    end
  end

  @doc """
  What a published story is called.

  A snapshot has no name of its own — it takes the world's, because that's what a
  reader is being offered. Asking a snapshot for `:name` gets nothing and renders
  *Untitled campaign* over a story that plainly has a title, so the question is
  answered here rather than by each surface guessing.
  """
  @spec title(Snapshot.t() | map()) :: String.t()
  def title(snapshot) do
    snapshot = snapshot || %{}

    # The bible's name first, then the payload's own — a snapshot has the former and a
    # campaign entry the latter, and a bookmark can point at either.
    case {Map.get(snapshot, :bible), Map.get(snapshot, :name)} do
      {%{name: n}, _} when is_binary(n) and n != "" -> n
      {_, n} when is_binary(n) and n != "" -> n
      _ -> "An untitled story"
    end
  end

  @doc "The outward blurb, and only that — never the bible itself (§2.12)."
  @spec blurb(Snapshot.t() | map()) :: String.t() | nil
  def blurb(snapshot) do
    case Map.get(snapshot || %{}, :bible) do
      %{cover: c} when is_binary(c) and c != "" -> c
      _ -> nil
    end
  end

  @doc "The publication settings on a snapshot, defaulting to the least-granting ones."
  @spec publication(Snapshot.t() | map()) :: Publication.t()
  def publication(snapshot), do: Publication.from(Map.get(snapshot, :publication))
end
