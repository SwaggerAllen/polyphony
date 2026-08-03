defmodule Polyphony.Authoring.Stub do
  @moduledoc """
  Character stubs (§B8) — the pattern locations already have via `origin:
  :discovered`, now for characters.

  A **stub** is a placeholder: a name, a one-line `role`, and the inbound
  `relationships` that gave rise to it — no authored sheet, facts, or voice. Stubs
  are created inline from a relationship editor, a campaign roster, or by the Director
  accepting a `:novel` proposal that references an unknown person.

  A stub carries `status: :stub` and reads as **pending** in the library until an
  author opens it and saves — at which point the editor flips it to `:full` (there is
  no separate promote/accept step). Its fields are written like any other character's,
  through the normal editor generation (`Polyphony.Authoring.Autofill`), which folds
  the stub's `role` into its context so the seed survives into what's generated. Until
  it is `:full` it is not castable (`Polyphony.SceneControl` refuses a non-`:full`
  character).
  """

  alias Polyphony.Authoring.CharacterSheet

  @doc """
  Create a stub: a name + one-line role (+ optional inbound `:relationships` and a
  `:world_bible_id` inherited from the character that spawned it, so the stub already
  belongs to the right setting).
  """
  @spec new(String.t(), String.t(), keyword()) :: CharacterSheet.t()
  def new(name, role, opts \\ []) do
    %CharacterSheet{
      name: name,
      role: role,
      status: :stub,
      # Written during play rather than cast deliberately, so they start as a
      # walk-on. Promotion is a real operation if they turn out to matter (§2.5).
      tier: :incidental,
      relationships: Keyword.get(opts, :relationships, []),
      world_bible_id: Keyword.get(opts, :world_bible_id)
    }
  end

  @doc "Is `sheet` a pending stub (not yet finalized to `:full`)?"
  def stub?(%CharacterSheet{status: :stub}), do: true
  def stub?(%CharacterSheet{}), do: false

  @doc "Is `sheet` finalized and usable (`:full`)?"
  def full?(%CharacterSheet{status: :full}), do: true
  def full?(%CharacterSheet{}), do: false
end
