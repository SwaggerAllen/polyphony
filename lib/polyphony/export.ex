defmodule Polyphony.Export do
  @moduledoc """
  Campaign export (§B6). Three artifacts, all built on primitives that already exist:

    * **Transcript** — a readable markdown rendering of a scene's events. Omniscient by
      default (the same disclosure as publishing, §B1) or, given a viewer, **as a
      character** — the per-perspective export, near-free because it is just
      `PolyphonyCore.Visibility.project/2` through the same filter play uses.
    * **Structured JSON** — the full omniscient event log plus pinned dependencies
      (essentially the frozen `Library.Snapshot`), for archival/portability.
    * **Sheet / bible JSON** — a single authored entity as JSON.

  Pure: it renders values passed in (canonical events, sheets), so it is tested
  offline against hand-written logs and never needs a store.
  """

  alias PolyphonyCore.Visibility
  alias Polyphony.Library.Snapshot

  alias PolyphonyCore.Events.{
    SpeechUttered,
    ThoughtOccurred,
    ActionTaken,
    DemeanorReported,
    PrivateStateReported,
    WorldEventOccurred,
    CharacterEntered,
    CharacterExited,
    BeatOpened
  }

  @doc """
  A markdown transcript of `events` for `viewer` (`:omniscient` by default, or
  `{:character, id}` for the per-perspective export). Events are projected through
  `Visibility` first, so a character export can never leak what that character
  couldn't see — the guarantee holds for exports exactly as it does in play.
  """
  @spec transcript([struct()], Visibility.viewer(), keyword()) :: String.t()
  def transcript(events, viewer \\ :omniscient, opts \\ []) do
    title = Keyword.get(opts, :title, heading(viewer))

    body =
      events
      |> Visibility.project(viewer)
      |> Enum.map(&line(&1, viewer))
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    "# #{title}\n\n#{body}\n"
  end

  @doc """
  Structured JSON export: the omniscient event log plus pinned dependencies (the
  frozen snapshot). `attrs` matches `Library.Snapshot.build/2` (bible, characters,
  arc, campaign_id, published_beat) plus `:events`.
  """
  @spec json(map() | keyword(), keyword()) :: String.t()
  def json(attrs, opts \\ []) do
    attrs = Map.new(attrs)
    events = Map.get(attrs, :events, [])

    Jason.encode!(
      %{
        campaign_id: Map.get(attrs, :campaign_id),
        snapshot:
          Snapshot.build(attrs, include_proposed: Keyword.get(opts, :include_proposed, false)),
        events: events |> Visibility.project(:omniscient) |> Enum.map(&event_map/1)
      },
      pretty: Keyword.get(opts, :pretty, false)
    )
  end

  @doc "A single authored entity (sheet, bible, …) as JSON."
  @spec entity_json(term(), keyword()) :: String.t()
  def entity_json(entity, opts \\ []),
    do: Jason.encode!(entity, pretty: Keyword.get(opts, :pretty, false))

  # ── Rendering ─────────────────────────────────────────────────────────────────

  defp heading(:omniscient), do: "Transcript (omniscient)"
  defp heading({:character, id}), do: "Transcript — as #{id}"

  # In a character export the interior of *others* is already filtered out by
  # `Visibility`; we still label the viewer's own interior distinctly.
  defp line(%BeatOpened{beat: beat}, _viewer), do: "\n## Beat #{beat}\n"
  defp line(%SpeechUttered{speaker_id: s, content: c}, _viewer), do: "**#{s}:** #{c}"
  defp line(%ActionTaken{character_id: ch, content: c}, _viewer), do: "*#{ch} #{c}*"
  defp line(%WorldEventOccurred{content: c}, _viewer), do: "> #{c}"
  defp line(%ThoughtOccurred{character_id: ch, content: c}, _viewer), do: "_(#{ch} thinks: #{c})_"

  defp line(%DemeanorReported{character_id: ch, demeanor: d}, _viewer)
       when d not in [nil, ""],
       do: "*#{ch} seems #{d}.*"

  defp line(%PrivateStateReported{character_id: ch, mood_felt: m}, _viewer)
       when m not in [nil, ""],
       do: "_(#{ch} feels #{m})_"

  defp line(%CharacterEntered{character_id: ch}, _viewer), do: "*(#{ch} enters)*"
  defp line(%CharacterExited{character_id: ch}, _viewer), do: "*(#{ch} leaves)*"
  defp line(_other, _viewer), do: nil

  # A JSON-safe shape for an event: its type plus its public fields.
  defp event_map(%mod{} = event) do
    event
    |> Map.from_struct()
    |> Map.put(:type, mod |> Module.split() |> List.last())
  end
end
