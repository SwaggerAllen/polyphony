defmodule Polyphony.Authoring.EffectiveWorldBible do
  @moduledoc """
  Materializes the **effective world bible** (§2.8): the authored `WorldBible` with
  the campaign's *canon* world-arc entries folded into `starting_canon`. The world
  counterpart to `EffectiveSheet`.

  Canon world facts append to the canon list, in beat order, so the existing
  `Canon:` block in both renderers surfaces them with no prompt-shape change. Only
  reviewed canon applies — proposed and retracted entries are ignored.

  **Propagation (§2.8).** A `:global` fact reaches every character everywhere. A
  `:local` fact reaches only where it happened — passed the scene's `location_id`,
  a local fact is included only when it matches, so a character elsewhere never
  learns it (dramatic irony at the world level). The **omniscient** view (the
  Director's brief) passes `:all` and sees every canon fact regardless of place.
  """

  alias Polyphony.Authoring.{WorldBible, WorldArcEntry}

  @doc """
  Fold canon world-arc entries into `bible`'s `starting_canon`. `reach` scopes local
  facts: `:all` (omniscient — every fact) or a scene `location_id` (global facts plus
  local facts at that location; `nil` ⇒ global only).
  """
  @spec apply(WorldBible.t(), [WorldArcEntry.t()], :all | String.t() | nil) :: WorldBible.t()
  def apply(%WorldBible{} = bible, entries, reach \\ :all) do
    additions =
      entries
      |> Enum.filter(&(&1.status == :canon))
      |> Enum.filter(&reaches?(&1, reach))
      |> Enum.sort_by(&(&1.beat || 0))
      # Folded in as **public** entries. A world-arc fact reached whoever was in
      # reach of it (`scope`/`location_id`) — that is *where* it landed, which is a
      # different axis from *who knows*, and there is no way yet to accumulate a
      # concealed one. When there is (`backend-backlog.md` §3.3), it lands here.
      |> Enum.map(&%WorldBible.Entry{statement: &1.statement})

    %{bible | starting_canon: WorldBible.entries(bible.starting_canon) ++ additions}
  end

  defp reaches?(%WorldArcEntry{scope: :global}, _reach), do: true
  defp reaches?(%WorldArcEntry{scope: :local}, :all), do: true

  defp reaches?(%WorldArcEntry{scope: :local, location_id: loc}, reach),
    do: not is_nil(loc) and loc == reach
end
