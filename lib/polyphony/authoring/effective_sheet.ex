defmodule Polyphony.Authoring.EffectiveSheet do
  @moduledoc """
  Materializes the **effective sheet** (§5): the authored `CharacterSheet` with
  the campaign's *canon* arc entries applied.

  Why materialize rather than present both: a revision contradicts the sheet, and
  showing "she's guarded… but actually now she isn't" invites the model to drift
  back to the original (§5). So we fold canon revisions in and cache the result,
  keeping the original immutable underneath (the caller retains it) so a campaign
  can always be diffed against the base character.

    * `:discovery` → **union**: append (a new fact, or into `initial_knowledge`).
    * `:revision`  → **override**: replace the named scalar field.
    * `:release`   → **open the line that gave**. `BoundaryGate` resolves a conditional
      boundary scene-locally from canon; a canon `:release` makes it permanent, which
      is the distinction the design draws — the gate resolved it in play, review is
      where it stops being scene-local.

  Proposed and retracted entries are ignored — only the reviewed canon applies.
  """

  alias Polyphony.Authoring.{CharacterSheet, ArcEntry}
  alias Polyphony.Authoring.CharacterSheet.Boundary

  @overridable_scalars ~w(premise appearance voice temperament backstory)

  @doc """
  Apply canon arc entries to a sheet, in beat order, producing the effective sheet.

  Entries authored with `timing: :always` fold **first**, whatever their beat: they
  correct the person originally written and sit before everything play has done, so
  her history stays and applies on top (STR-62).
  """
  @spec apply(CharacterSheet.t(), [ArcEntry.t()]) :: CharacterSheet.t()
  def apply(%CharacterSheet{} = sheet, arc_entries) do
    arc_entries
    |> Enum.filter(&(&1.status == :canon))
    |> Enum.sort_by(&{if(&1.timing == :always, do: 0, else: 1), &1.beat || 0})
    |> Enum.reduce(sheet, &apply_entry/2)
  end

  # ── Authored operations (STR-62) ─────────────────────────────────────────────
  #
  # The authoring form's list operations name *which one* via `replaces`, so they
  # fold by matching it. An unmatched target is a no-op, same rule as an unmatched
  # released topic: a retitled item must not take the sheet down with it.

  # Removing is not deleting: the entry stays in the history (it is canon); the fold
  # simply stops carrying the item forward from here.
  defp apply_entry(%ArcEntry{operation: :remove, sheet_field: "facts"} = e, sheet) do
    target = e.replaces || e.statement

    %CharacterSheet{
      sheet
      | facts: Enum.reject(sheet.facts || [], &(normalize(&1.statement) == normalize(target)))
    }
  end

  defp apply_entry(%ArcEntry{operation: :remove, sheet_field: "boundaries"} = e, sheet) do
    target = e.replaces || e.statement

    %CharacterSheet{
      sheet
      | boundaries:
          Enum.reject(sheet.boundaries || [], &(normalize(&1.topic) == normalize(target)))
    }
  end

  # Removing a relationship ends one direction; what the other party thinks is a
  # separate entry on their sheet and is untouched.
  defp apply_entry(%ArcEntry{operation: :remove, sheet_field: "relationships"} = e, sheet) do
    %CharacterSheet{
      sheet
      | relationships: Enum.reject(sheet.relationships || [], &relationship_match?(&1, e))
    }
  end

  # Changing one fact in the list: `replaces` names it, the statement supersedes it.
  defp apply_entry(
         %ArcEntry{operation: :change, sheet_field: "facts", replaces: replaces} = e,
         sheet
       )
       when is_binary(replaces) and replaces != "" do
    %CharacterSheet{
      sheet
      | facts:
          Enum.map(sheet.facts || [], fn f ->
            if normalize(f.statement) == normalize(replaces),
              do: %CharacterSheet.Fact{f | statement: e.statement},
              else: f
          end)
    }
  end

  # Changing a line rewrites its pair — the until and the and-then — in place.
  defp apply_entry(
         %ArcEntry{operation: :change, sheet_field: "boundaries", replaces: replaces} = e,
         sheet
       )
       when is_binary(replaces) and replaces != "" do
    %CharacterSheet{
      sheet
      | boundaries:
          Enum.map(sheet.boundaries || [], fn b ->
            if normalize(b.topic) == normalize(replaces), do: authored_line(e, b), else: b
          end)
    }
  end

  defp apply_entry(%ArcEntry{operation: :change, sheet_field: "relationships"} = e, sheet) do
    %CharacterSheet{
      sheet
      | relationships:
          Enum.map(sheet.relationships || [], fn r ->
            if relationship_match?(r, e),
              do: %CharacterSheet.Relationship{r | descriptor: e.statement},
              else: r
          end)
    }
  end

  # An authored line, added: never (no condition) or earnable (until + and then).
  defp apply_entry(%ArcEntry{operation: :add, sheet_field: "boundaries"} = e, sheet) do
    %CharacterSheet{sheet | boundaries: (sheet.boundaries || []) ++ [authored_line(e, nil)]}
  end

  # An authored relationship, added: one direction only.
  defp apply_entry(%ArcEntry{operation: :add, sheet_field: "relationships"} = e, sheet) do
    %CharacterSheet{
      sheet
      | relationships:
          (sheet.relationships || []) ++
            [
              %CharacterSheet.Relationship{
                target: e.target,
                target_id: e.target_id,
                descriptor: e.statement
              }
            ]
    }
  end

  # An authored fact carries its audience and always-in-mind flag from the form.
  defp apply_entry(%ArcEntry{operation: :add, sheet_field: "facts"} = e, sheet) do
    %CharacterSheet{
      sheet
      | facts:
          (sheet.facts || []) ++
            [
              %CharacterSheet.Fact{
                statement: e.statement,
                core: e.core || false,
                concealed: e.concealed || false,
                audience: e.audience
              }
            ]
    }
  end

  # A line gave, permanently — extracted, authored (`operation: :satisfied`), or the
  # Director proposing past the written condition; by the time it is canon the
  # distinction was the review's to make, and the fold treats all three the same.
  # Matched on the topic the extractor named; an unmatched topic is a no-op rather
  # than a crash, because a retitled boundary must not take the sheet down with it.
  defp apply_entry(%ArcEntry{kind: :release, released_topic: topic}, sheet)
       when is_binary(topic) and topic != "" do
    %CharacterSheet{
      sheet
      | boundaries: Enum.map(sheet.boundaries || [], &release_if(&1, topic))
    }
  end

  # Revision of a known scalar field → override.
  defp apply_entry(%ArcEntry{kind: :revision, sheet_field: field, statement: stmt}, sheet)
       when field in @overridable_scalars do
    Map.put(sheet, String.to_existing_atom(field), stmt)
  end

  # Discovery into initial_knowledge → union.
  defp apply_entry(
         %ArcEntry{kind: :discovery, sheet_field: "initial_knowledge", statement: stmt},
         sheet
       ) do
    %{sheet | initial_knowledge: sheet.initial_knowledge ++ [stmt]}
  end

  # Free-standing discovery (or any other field) → promote to a fact (§6.1 round trip).
  defp apply_entry(%ArcEntry{kind: :discovery, statement: stmt}, sheet) do
    %{sheet | facts: sheet.facts ++ [%CharacterSheet.Fact{statement: stmt, core: false}]}
  end

  # Anything else (e.g. a revision naming an unknown field) is left as-is rather
  # than silently corrupting the sheet.
  defp apply_entry(%ArcEntry{}, sheet), do: sheet

  defp release_if(%Boundary{topic: t} = b, topic) do
    if normalize(t) == normalize(topic), do: %Boundary{b | stance: :open}, else: b
  end

  # The line an authoring entry describes. `base` keeps whatever the change didn't
  # touch (an add starts from nothing). No condition means a *never* (`:closed`); a
  # condition makes it earnable (`:conditional`) with its consequence written now.
  defp authored_line(%ArcEntry{} = e, base) do
    base = base || %Boundary{}
    condition = present(e.line_condition)

    %Boundary{
      base
      | topic: e.statement,
        direction: e.direction || base.direction || :refusal,
        stance: if(condition, do: :conditional, else: :closed),
        condition: condition,
        after_release: present(e.after_release) || base.after_release
    }
  end

  defp relationship_match?(r, %ArcEntry{target_id: tid, replaces: replaces, target: target}) do
    cond do
      is_binary(tid) and tid != "" -> to_string(r.target_id) == tid
      is_binary(replaces) and replaces != "" -> normalize(r.descriptor) == normalize(replaces)
      is_binary(target) and target != "" -> normalize(r.target) == normalize(target)
      true -> false
    end
  end

  defp present(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  defp present(_), do: nil

  defp normalize(s), do: s |> to_string() |> String.trim() |> String.downcase()
end
