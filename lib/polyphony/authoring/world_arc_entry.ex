defmodule Polyphony.Authoring.WorldArcEntry do
  @moduledoc """
  A durable, campaign-scoped change to the **world**, discovered during play (§2.8).

  The world counterpart to `Polyphony.Authoring.ArcEntry`. `WorldBible.starting_canon`
  is fixed and `WorldEventOccurred` is a *moment*, not a *fact* — so this is where
  "the moon fell out of the sky" lives as durable, standing canon that can reach a
  character who was off-screen when it happened.

  Like character arc, everything enters `:proposed`; review promotes it to `:canon`,
  and only canon feeds the effective world bible.

    * `:discovery` — a newly-true world fact (additive to canon).
    * `:revision`  — an update to existing canon (folded in as a superseding statement,
      read in beat order; no field-level targeting — world canon is a list, not fields).

  **Propagation** (`scope`) is what keeps world facts honest as dramatic irony:

    * `:global` — everyone comes to know it; always in the world half of context.
    * `:local`  — known at `location_id` first; injected into context only for scenes
      at that location, so a character elsewhere doesn't magically know it.

  Per the design, world arc injects **facts**, never a character's reaction — an
  off-screen character catches up by the fact being present in their next scene and
  reacting on screen, not by a silent sheet rewrite.

  ## Who knows

  A character's arc is theirs; a world's arc is **everyone's**, which means it also has
  to say who knows it — and that is the audience picker doing the same job it does on a
  secret (§3.3, `ux/polyphony-arc.html` §03). Two answers cover almost every case:

    * **Everyone** — common knowledge, no scoping. `audience: nil` with
      `concealed: false`. Anyone off-screen is told the next time they turn up and
      reacts to it on the page, which is what fixes the off-screen problem: not
      extrapolation, just the fact delivered and a scene to react in.
    * **Whoever was there** — `audience` with `scene: true`, resolved against the cast
      of `source_scene_id`. Arc is the one thing that *has* a source scene, which is why
      this row can exist here and couldn't on authored canon.

  `scope` is a different axis and stays one: it says *where* a fact landed, not who
  knows it.
  """
  @derive Jason.Encoder
  defstruct [
    :kind,
    :statement,
    :reason,
    :audience,
    :beat,
    :source_scene_id,
    :location_id,
    concealed: false,
    scope: :global,
    status: :proposed,
    promotable: true
  ]

  @type scope :: :global | :local

  @type t :: %__MODULE__{
          kind: :discovery | :revision,
          statement: String.t(),
          beat: integer() | nil,
          source_scene_id: term() | nil,
          location_id: String.t() | nil,
          scope: scope(),
          status: :proposed | :canon | :retracted,
          promotable: boolean()
        }
end
