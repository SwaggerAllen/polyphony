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

  Proposed and retracted entries are ignored — only the reviewed canon applies.
  """

  alias Polyphony.Authoring.{CharacterSheet, ArcEntry}

  @overridable_scalars ~w(premise appearance voice temperament backstory)

  @doc "Apply canon arc entries to a sheet, in beat order, producing the effective sheet."
  @spec apply(CharacterSheet.t(), [ArcEntry.t()]) :: CharacterSheet.t()
  def apply(%CharacterSheet{} = sheet, arc_entries) do
    arc_entries
    |> Enum.filter(&(&1.status == :canon))
    |> Enum.sort_by(&(&1.beat || 0))
    |> Enum.reduce(sheet, &apply_entry/2)
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
end
