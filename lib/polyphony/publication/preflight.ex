defmodule Polyphony.Publication.Preflight do
  @moduledoc """
  What a campaign looks like from the outside, gathered before publishing.

  Two jobs, and they are the same read:

    * **The scenes a snapshot carries** — id, title, cast and beat count, oldest first.
      Frozen into the snapshot because the contents list, the reading position (§3.1e)
      and the perspective selector all need them and none of them may ask the author's
      live campaign; that coupling is the thing publishing exists to break.
    * **The scenes nobody will be able to read** (§3.1c-ii). If spectator is off and a
      scene contains none of the published cast, no reader can open it. That's a
      legitimate authorial choice — *sometimes a gap is the point* — but it must not
      happen by accident, so publish says so first and offers the two obvious fixes.

  Cast is derived from the **stream**, through `Polyphony.MembershipSet`, rather than
  from the campaign's roster: who was actually in a scene is a fact about what happened,
  and a character added to the campaign afterwards was not in it.
  """

  alias Polyphony.{App, MembershipSet, Packets, Publication}
  alias Polyphony.Events.SceneOpened

  @doc """
  Describe each of `scene_ids`, oldest first.

  The campaign stores its scenes newest-first (it prepends), and a story is read the
  other way round — so this reverses, and everything downstream can take the order at
  face value.
  """
  @spec scenes([term()]) :: [map()]
  def scenes(scene_ids) do
    scene_ids
    |> Enum.reverse()
    |> Enum.map(&describe/1)
  end

  @doc "One scene: `%{id:, title:, premise:, cast:, beats:}`."
  @spec describe(term()) :: map()
  def describe(scene_id) do
    events = stored_events(scene_id)
    opened = Enum.find(events, &match?(%SceneOpened{}, &1))

    %{
      id: scene_id,
      title: (opened && opened.location_id) || "A scene",
      # The premise stands in for a summary in a published contents list, because a
      # summary says how the scene turned out.
      premise: opened && opened.premise,
      cast: cast(events),
      beats: beats(events)
    }
  end

  @doc """
  The warning publish shows, or `nil` when there's nothing to warn about.

  `%{scenes: [...], fixes: [:spectator | {:share, character_id}]}` — the two fixes the
  design names: turn spectator on, or share one of the people who were there.
  """
  @spec warning(Publication.t(), [map()]) :: map() | nil
  def warning(%Publication{} = pub, scenes) do
    case Publication.unreadable_scenes(pub, scenes) do
      [] -> nil
      unreadable -> %{scenes: unreadable, fixes: fixes(unreadable)}
    end
  end

  # Turning spectator on fixes every unreadable scene at once, so it leads. Sharing a
  # person only fixes the scenes they were in — offered per candidate, and only for
  # people who actually appear in an unreachable scene.
  defp fixes(unreadable) do
    candidates =
      unreadable
      |> Enum.flat_map(&(Map.get(&1, :cast) || []))
      |> Enum.uniq()
      |> Enum.map(&{:share, &1})

    [:spectator | candidates]
  end

  defp cast(events) do
    events
    |> MembershipSet.from_events()
    |> Map.get(:intervals, [])
    |> Enum.map(& &1.character_id)
    |> Enum.uniq()
  end

  defp beats(events) do
    events
    |> Enum.map(&Map.get(&1, :beat))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> 0
      beats -> Enum.max(beats)
    end
  end

  defp stored_events(scene_id) do
    App
    |> Commanded.EventStore.stream_forward(scene_id)
    |> Enum.map(& &1.data)
    |> Packets.canonical()
  rescue
    _ -> []
  end
end
