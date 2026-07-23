defmodule Polyphony.Context.SceneContext do
  @moduledoc """
  The materialized, **frozen-at-scene-open** context for one character in one
  scene (§9). The `prefix` is the cache unit: everything above the scene-premise
  line, assembled once and reused for every turn in the scene.

  Holding it as a struct makes the caching discipline explicit — `prefix` is
  computed by `Polyphony.Context.materialize/1` and never touched again for the
  life of the scene, so the stable portion of every prompt is byte-identical and
  the provider's prefix cache actually lands.
  """
  @enforce_keys [:scene_id, :character_id, :premise, :prefix]
  defstruct [:scene_id, :character_id, :premise, :prefix, meta: %{}]

  @type t :: %__MODULE__{
          scene_id: term(),
          character_id: term(),
          premise: String.t() | nil,
          prefix: String.t(),
          meta: map()
        }
end
