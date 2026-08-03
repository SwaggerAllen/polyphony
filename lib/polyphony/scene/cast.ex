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
  alias Polyphony.TurnPacket
  alias Polyphony.TurnPacket.Move

  defstruct id_to_name: %{}, name_to_id: %{}, id_to_hue: %{}

  @type t :: %__MODULE__{
          id_to_name: %{String.t() => String.t()},
          name_to_id: %{String.t() => String.t()},
          id_to_hue: %{String.t() => pos_integer()}
        }

  @doc "Build the id↔name map for a scene from the characters that have entered it."
  @spec for_scene(term()) :: t()
  def for_scene(scene_id) do
    sheets =
      for id <- entered_ids(scene_id),
          %CharacterSheet{name: n} = sheet <- [Rebuild.sheet_for(scene_id, id)],
          is_binary(n) and n != "",
          do: {to_string(id), sheet}

    pairs = for {id, sheet} <- sheets, do: {id, sheet.name}

    %__MODULE__{
      id_to_name: Map.new(pairs),
      name_to_id: Map.new(pairs, fn {id, name} -> {name, id} end),
      # The voice colour is stored on the sheet, so it comes along with the name —
      # same read, and a rename or a cast change can't move it.
      id_to_hue: Map.new(sheets, fn {id, sheet} -> {id, sheet.hue} end)
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

  @doc """
  Resolve a packet's whisper addressees from display names to character ids.

  **This is the gate that keeps names out of the log.** A whisper's `addressed_to`
  is not decoration — `Visibility.visible_to?/3` matches a character against
  `[speaker_id | addressed_to]`, so it is the routing key for the one event type
  that is deliberately visible to a subset. If a name lands there while viewers are
  ids, the whisper reaches nobody: fail-*safe* under default-deny (a caught
  functional bug, never a leak), but a bug all the same. If it lands there and a
  character is later renamed, the same whisper stops reaching someone it used to.

  So every path that produces a packet — the model, the composer, an edit, an
  accepted draft — runs it through here before `CommitPacket`. Non-speech moves and
  aloud speech are untouched; only `addressed_to` is rewritten. Unknown names pass
  through as themselves (the identity fallback), so a whisper to someone outside the
  scene degrades to "nobody hears it" rather than raising.

  Takes either a cast you already hold or a `scene_id` to build one from; the latter
  reads the scene's stream, so pass a cast when committing several packets.
  """
  @spec resolve_addressees(t() | term(), TurnPacket.t()) :: TurnPacket.t()
  def resolve_addressees(cast_or_scene, packet)

  def resolve_addressees(%__MODULE__{} = cast, %TurnPacket{moves: moves} = packet) do
    %TurnPacket{packet | moves: Enum.map(moves, &resolve_move(cast, &1))}
  end

  def resolve_addressees(scene_id, %TurnPacket{} = packet),
    do: scene_id |> for_scene() |> resolve_addressees(packet)

  defp resolve_move(cast, %Move{addressed_to: to} = move) when is_list(to) and to != [],
    do: %Move{move | addressed_to: Enum.map(to, &resolve_id(cast, &1))}

  defp resolve_move(_cast, move), do: move

  @doc """
  Render character ids back to display names, for text a human reads or writes.

  The inverse of `resolve_addressees/2`, and the reason a rename is safe: the log
  keeps ids, and every surface that shows a whisper's addressees — the transcript,
  the turn editor — renders through here, so it shows whoever that id is *now*.
  """
  @spec render_names(t(), [term()]) :: [String.t()]
  def render_names(%__MODULE__{} = cast, ids) when is_list(ids),
    do: Enum.map(ids, &render_name(cast, &1))

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
