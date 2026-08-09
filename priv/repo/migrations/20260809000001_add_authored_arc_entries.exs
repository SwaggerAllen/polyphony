defmodule Polyphony.Repo.Migrations.AddAuthoredArcEntries do
  @moduledoc """
  STR-62: authored arc entries as proposals, satisfaction as an operation, and the
  Director proposing past a written condition.

  All columns are nullable — an extracted proposal carries none of them, so the
  existing rows read exactly as they always did. `author` is what distinguishes an
  authored card from an extracted one; `operation` is the authoring form's axis
  (add / change / remove / satisfied); `timing` is when it became true (always /
  scene / now). `replaces` is the list item or value a change supersedes (the
  authored card's Was line). `direction`, `line_condition` and `after_release`
  carry an authored line; `condition_met` marks a release proposal whose written
  condition did not fire (the Director going past it). `core` is an authored
  fact's always-in-mind flag; `target` / `target_id` are a relationship's
  direction.
  """
  use Ecto.Migration

  def change do
    alter table(:arc_entries) do
      add(:author, :string)
      add(:operation, :string)
      add(:timing, :string)
      add(:replaces, :text)
      add(:direction, :string)
      add(:line_condition, :text)
      add(:after_release, :text)
      add(:condition_met, :boolean)
      add(:core, :boolean)
      add(:target, :string)
      add(:target_id, :string)
    end
  end
end
