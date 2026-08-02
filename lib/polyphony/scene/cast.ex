defmodule Polyphony.Scene.Cast do
  @moduledoc """
  A scene's character **id ↔ display name** map (§5.2 identity migration).

  The event log keys characters by a stable `character_id`; the fiction — prompts, the
  whisper syntax, the Director's cast picks — speaks **display names**. This resolves
  between them at the LLM boundary: render a name for an id when building a prompt, and
  resolve an emitted name back to an id before it enters the log. Visibility, membership,
  and packet ids stay **pure-id**, so a rename can't misroute a whisper.

  **Identity fallback.** An id with no resolvable sheet renders as itself, and a name with
  no cast match resolves to itself. So a scene keyed by names (tests, or streams from
  before the mint flip) is a no-op, and an unfamiliar name the model emits passes through
  unchanged rather than vanishing.

  Names are unique within a scene by construction (a duplicate name would already have
  collided when `character_id` *was* the name), so `name_to_id` is unambiguous.
  """
  alias Polyphony.App
  alias Polyphony.Context.Rebuild
  alias Polyphony.Authoring.CharacterSheet
  alias Polyphony.Events.CharacterEntered

  defstruct id_to_name: %{}, name_to_id: %{}

  @type t :: %__MODULE__{
          id_to_name: %{String.t() => String.t()},
          name_to_id: %{String.t() => String.t()}
        }

  @doc "Build the id↔name map for a scene from the characters that have entered it."
  @spec for_scene(term()) :: t()
  def for_scene(scene_id) do
    pairs =
      for id <- entered_ids(scene_id),
          %CharacterSheet{name: n} <- [Rebuild.sheet_for(scene_id, id)],
          is_binary(n) and n != "",
          do: {to_string(id), n}

    %__MODULE__{
      id_to_name: Map.new(pairs),
      name_to_id: Map.new(pairs, fn {id, name} -> {name, id} end)
    }
  end

  @doc "The display name for a character id (the id itself when unknown)."
  @spec render_name(t(), term()) :: String.t()
  def render_name(%__MODULE__{id_to_name: m}, id) do
    id = to_string(id)
    Map.get(m, id, id)
  end

  @doc "The character id for a display name the model/human emitted (the name itself when unknown)."
  @spec resolve_id(t(), term()) :: String.t()
  def resolve_id(%__MODULE__{name_to_id: m}, name) do
    name = to_string(name)
    Map.get(m, name, name)
  end

  defp entered_ids(scene_id) do
    scene_id
    |> stored_events()
    |> Enum.flat_map(fn
      %CharacterEntered{character_id: id} -> [to_string(id)]
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp stored_events(scene_id) do
    App |> Commanded.EventStore.stream_forward(scene_id) |> Enum.map(& &1.data)
  rescue
    _ -> []
  end
end
