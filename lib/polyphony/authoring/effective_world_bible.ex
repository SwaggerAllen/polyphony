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

  alias Polyphony.Authoring.{Audience, WorldBible, WorldArcEntry}

  @doc """
  Fold canon world-arc entries into `bible`'s `starting_canon`. `reach` scopes local
  facts: `:all` (omniscient — every fact) or a scene `location_id` (global facts plus
  local facts at that location; `nil` ⇒ global only).
  """
  @spec apply(WorldBible.t(), [WorldArcEntry.t()], :all | String.t() | nil, keyword()) ::
          WorldBible.t()
  def apply(%WorldBible{} = bible, entries, reach \\ :all, opts \\ []) do
    members_of = Keyword.get(opts, :scene_members, fn _scene_id -> [] end)

    applicable =
      entries
      |> Enum.filter(&(&1.status == :canon))
      |> Enum.filter(&reaches?(&1, reach))
      |> Enum.sort_by(&{if(&1.timing == :always, do: 0, else: 1), &1.beat || 0})

    # An authored entry names its list (`sheet_field: "rules"` or canon) and may be a
    # list operation (`:change` / `:remove` naming its target via `replaces`); an
    # extracted entry is always an addition to canon.
    {rules_entries, canon_entries} = Enum.split_with(applicable, &(&1.sheet_field == "rules"))

    %{
      bible
      | starting_canon:
          fold_list(WorldBible.entries(bible.starting_canon), canon_entries, members_of),
        rules: fold_list(WorldBible.entries(bible.rules), rules_entries, members_of)
    }
  end

  # `scope` said *where* it landed; the entry's own audience says *who knows*, and
  # the two stay separate axes. "Everyone" folds in public — which is what fixes the
  # off-screen problem, since the fact is simply present the next time they turn up.
  # "Whoever was there" folds in concealed, with the scene's cast as its audience.
  defp fold_list(base, entries, members_of) do
    Enum.reduce(entries, base, fn e, acc ->
      case e.operation do
        :remove ->
          target = e.replaces || e.statement
          Enum.reject(acc, &(normalize(&1.statement) == normalize(target)))

        :change when is_binary(e.replaces) and e.replaces != "" ->
          Enum.map(acc, fn item ->
            if normalize(item.statement) == normalize(e.replaces),
              do: %WorldBible.Entry{item | statement: e.statement},
              else: item
          end)

        _add_or_extracted ->
          acc ++ [fold_entry(e, members_of)]
      end
    end)
  end

  defp normalize(s), do: s |> to_string() |> String.trim() |> String.downcase()

  # A **whoever was there** audience is expanded here, into the actual cast of the
  # scene the fact came from — unlike a group, which is named and never expanded.
  # The difference is that a scene's cast is finished history and cannot change, so
  # expanding it can't go stale; a group's membership moves, which is the whole reason
  # naming it is the point.
  defp fold_entry(%WorldArcEntry{audience: %Audience{scene: true} = a} = e, members_of) do
    resolved =
      Enum.reduce(members_of.(e.source_scene_id), a, &Audience.add_character(&2, &1))

    %WorldBible.Entry{
      statement: e.statement,
      concealed: e.concealed,
      audience: %Audience{resolved | scene: false}
    }
  end

  defp fold_entry(%WorldArcEntry{} = e, _members_of),
    do: %WorldBible.Entry{statement: e.statement, concealed: e.concealed, audience: e.audience}

  defp reaches?(%WorldArcEntry{scope: :global}, _reach), do: true
  defp reaches?(%WorldArcEntry{scope: :local}, :all), do: true

  defp reaches?(%WorldArcEntry{scope: :local, location_id: loc}, reach),
    do: not is_nil(loc) and loc == reach
end
