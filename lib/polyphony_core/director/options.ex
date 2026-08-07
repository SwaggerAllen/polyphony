defmodule PolyphonyCore.Director.Options do
  @moduledoc """
  The valid option set for a scene (§10): the exits and interactable entities a
  character may propose against.

  Injecting this into the character's context is what lets `:exit`/`:interact`
  proposals be enums rather than freeform — "same philosophy as constrained
  decoding, one level up." Stage-1 arbitration then only has to validate the
  rare mismatch and the always-freeform `:novel`.
  """

  @type t :: %{exits: [String.t()], entities: [String.t()]}

  @doc """
  Build the option set from a location's connections and the entities present in
  the scene. `connections` is a list of `%{label: ..., to_id: ...}` (or maps with
  those keys); `entities` is a list of entity ids present.
  """
  @spec for_scene([map()], [term()]) :: t()
  def for_scene(connections, entities) do
    %{
      exits: Enum.map(connections, &connection_label/1),
      entities: Enum.map(entities, &to_string/1)
    }
  end

  defp connection_label(%{label: label}) when is_binary(label), do: label
  defp connection_label(%{to_id: to_id}), do: to_string(to_id)
  defp connection_label(other), do: to_string(other)
end
