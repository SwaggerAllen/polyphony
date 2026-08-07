defmodule Polyphony.Core.Publication do
  @moduledoc """
  What publishing decides (§3.1, §3.1c) — **two separate questions, not one ladder**.

    * **How it's meant to be read** is a content decision: which perspectives a reader
      may adopt. Spectator isn't a lesser tier, it's one of the options, and a
      publisher can leave it out if the story doesn't work without someone's head.
    * **Whether the authoring surface is exposed** is a permission decision, and it's a
      single checkbox: `forkable`. Sheets come with it, because a fork has to be able
      to carry the story on and can't do that from prose alone.

  An earlier draft made these one four-rung ladder, which conflated two unrelated
  decisions and made "readable as two people" imply "copyable".

  ## Perspectives rather than per-surface toggles

  Publication **names the perspectives a reader may adopt**, and `Polyphony.Core.Visibility`
  does the filtering it already does in play. Enumerating authoring surfaces instead
  would mean every new feature ships a new toggle and the defaults rot; filtering by
  perspective covers surfaces that don't exist yet, for free — provided the rule holds
  that any new surface declares its visibility and **defaults to invisible**.

  It is also the **spoiler control**, not a reading preference: omniscient exposes
  every private thought, so if a character is secretly working against the others,
  publishing their head hands that away on page one. Only the author knows which
  perspectives are meant to be read — which is why nothing here has a clever default
  that opens one.

  ## Limited omniscient is the offer, not the fallback

  Where more than one perspective is granted, *everyone the author shared* is the mode
  a reader who just wants the story will pick: it needs no choice from them, and it's
  the only one that reads like fiction rather than a record (§3.1b). Spectator is a
  real option and a perfectly good read, but it is the default only because it is the
  one setting that reveals nothing.

  ## This is not library visibility

  Publication grants access to the **frozen snapshot's embedded copies**; library
  visibility (§7) governs the **live entry**. They look similar and must never be
  merged — reading a published campaign never reaches the author's live world.
  """

  alias Polyphony.Core.Visibility

  @derive Jason.Encoder
  defstruct perspectives: [],
            spectator: true,
            forkable: false

  @type t :: %__MODULE__{
          perspectives: [term()],
          spectator: boolean(),
          forkable: boolean()
        }

  @typedoc "A reader's choice, and what `Visibility` is asked with."
  @type mode :: :limited | :spectator | {:character, term()}

  @doc """
  Coerce a stored value into settings.

  A snapshot published before this existed has no settings at all. That reads as
  **spectator only** — no interiority, nothing forkable — which is the default-deny
  answer: it grants the least, and an author who wanted more can say so.
  """
  @spec from(t() | map() | nil) :: t()
  def from(%__MODULE__{} = pub), do: pub
  def from(nil), do: %__MODULE__{}

  def from(%{} = m) do
    %__MODULE__{
      perspectives: (get(m, :perspectives) || []) |> List.wrap() |> Enum.map(&to_string/1),
      spectator: truthy?(get(m, :spectator), true),
      forkable: truthy?(get(m, :forkable), false)
    }
  end

  defp get(m, key), do: Map.get(m, key, Map.get(m, to_string(key)))

  defp truthy?(nil, default), do: default
  defp truthy?(v, _default) when is_boolean(v), do: v
  defp truthy?(v, _default), do: v in ["true", "on", "1", 1]

  @doc """
  The modes a reader may choose, in the order the front page offers them.

  Limited omniscient leads where it exists, because it's what someone who just wants
  the story will pick. Named characters follow in the publisher's own order.
  """
  @spec modes(t()) :: [mode()]
  def modes(%__MODULE__{} = pub) do
    limited = if limited?(pub), do: [:limited], else: []
    spectator = if pub.spectator, do: [:spectator], else: []
    limited ++ spectator ++ Enum.map(pub.perspectives, &{:character, &1})
  end

  @doc """
  Is *everyone the author shared* on offer?

  Only above one perspective. With exactly one it would be the same read as that
  character under a name that promises more, which is a worse offer than the honest
  one.
  """
  @spec limited?(t()) :: boolean()
  def limited?(%__MODULE__{perspectives: p}), do: length(p) > 1

  @doc """
  The mode a reader lands on when they haven't chosen.

  *Everyone shared* where it exists, then spectator, then the single granted head.
  `nil` when the publication grants nothing at all, which is a real state and not an
  error — the author published a record nobody was given a way into.
  """
  @spec default_mode(t()) :: mode() | nil
  def default_mode(%__MODULE__{} = pub), do: pub |> modes() |> List.first()

  @doc """
  Is `mode` actually on offer? The gate every read goes through.

  Default-deny: a mode this publication didn't grant is refused, including a character
  who is in the story but whose head the author kept back. A URL naming them is not a
  grant.
  """
  @spec offers?(t(), mode()) :: boolean()
  def offers?(%__MODULE__{} = pub, mode), do: mode in modes(pub)

  @doc """
  Turn a reader's mode into a `Polyphony.Core.Visibility` viewer.

  The whole point of §3.1: publication decides *who you may be*, and the existing
  predicate decides what that person sees. No second implementation of visibility
  lives here — this function is the entire seam.
  """
  @spec viewer(t(), mode()) :: Visibility.viewer()
  def viewer(%__MODULE__{perspectives: ids}, :limited), do: {:readers, ids}
  def viewer(_pub, :spectator), do: :spectator
  def viewer(_pub, {:character, id}), do: {:character, to_string(id)}

  @doc """
  A mode as a URL/storage value, and back.

  One implementation, because three callers need it and they must agree: the reading
  view's `?as=`, the bookmark that remembers where you were (§3.1e), and the library's
  link back into both. A perspective that round-trips differently through a URL than
  through storage is a bookmark that quietly lands you in the wrong head.

  Always a string, so a stored value and a query parameter are the same thing.
  """
  @spec to_param(mode() | nil) :: String.t() | nil
  def to_param(:limited), do: "limited"
  def to_param(:spectator), do: "spectator"
  def to_param({:character, id}), do: to_string(id)
  def to_param(_), do: nil

  @doc """
  Parse a param back into a mode — `nil` when there's nothing to parse.

  Anything unrecognised reads as a character id rather than as an error, and
  `offers?/2` is what actually decides whether it's allowed. Parsing is not
  authorization, and keeping the two apart is what stops a typo in a URL becoming a
  500 instead of a fallback.
  """
  @spec from_param(String.t() | atom() | nil) :: mode() | nil
  def from_param(nil), do: nil
  def from_param(""), do: nil
  def from_param(:limited), do: :limited
  def from_param(:spectator), do: :spectator
  def from_param("limited"), do: :limited
  def from_param("spectator"), do: :spectator
  def from_param({:character, _} = mode), do: mode
  def from_param(id), do: {:character, to_string(id)}

  @doc "How a mode reads on the front page and in the selector."
  @spec label(mode(), String.t() | nil, map()) :: String.t()
  def label(mode, author \\ nil, names \\ %{})

  def label(:limited, nil, _names), do: "Everyone the author shared"
  def label(:limited, author, _names), do: "Everyone #{author} shared"
  def label(:spectator, _author, _names), do: "As a spectator"

  def label({:character, id}, _author, names),
    do: "As " <> to_string(Map.get(names, to_string(id), id))

  @doc "The one-line explanation under a mode, which is where the honesty lives."
  @spec blurb(mode()) :: String.t()
  def blurb(:limited), do: "Every published head at once — reads like a novel"
  def blurb(:spectator), do: "Everything said and done, nobody's thoughts"
  def blurb({:character, _}), do: "Only what they knew, when they knew it"

  # ── The pre-flight check (§3.1c-ii) ──────────────────────────────────────────

  @doc """
  Can `mode` show this scene at all?

  A character can only show you a scene they were in; spectator and limited omniscient
  can show any scene with anyone in it. `cast` is the scene's membership as character
  ids.
  """
  @spec covers_scene?(t(), mode(), [term()]) :: boolean()
  def covers_scene?(_pub, :spectator, _cast), do: true

  def covers_scene?(%__MODULE__{perspectives: ids}, :limited, cast),
    do: Enum.any?(cast, &(to_string(&1) in ids))

  def covers_scene?(_pub, {:character, id}, cast),
    do: Enum.any?(cast, &(to_string(&1) == to_string(id)))

  @doc """
  The modes that can show this scene, with `current` kept last rather than removed.

  The selector must never reorder under the reader — dropping their current
  perspective would make the control jump at exactly the moment they're trying to use
  it — so it sinks to the bottom, marked, instead of vanishing.
  """
  @spec modes_for_scene(t(), [term()], mode() | nil) :: %{can: [mode()], cannot: [mode()]}
  def modes_for_scene(%__MODULE__{} = pub, cast, current \\ nil) do
    {can, cannot} = pub |> modes() |> Enum.split_with(&covers_scene?(pub, &1, cast))

    if current && current in can do
      %{can: Enum.reject(can, &(&1 == current)) ++ [current], cannot: cannot}
    else
      %{can: can, cannot: cannot}
    end
  end

  @doc """
  Scenes no granted perspective can reach — what publish must warn about (§3.1c-ii).

  `scenes` is `[%{id:, title:, cast: [character_id]}]`. A gap can be the point, so this
  never blocks; it exists so the gap can't happen **by accident**. With spectator on
  there is nothing to warn about, which is why *turn spectator on* is one of the two
  fixes the screen offers.

  Unreadable scenes still appear in the contents, marked — silently omitting them would
  make the numbering lie and the story jump.
  """
  @spec unreadable_scenes(t(), [map()]) :: [map()]
  def unreadable_scenes(%__MODULE__{spectator: true}, _scenes), do: []

  def unreadable_scenes(%__MODULE__{} = pub, scenes) do
    Enum.reject(scenes, fn scene ->
      cast = Map.get(scene, :cast) || []
      Enum.any?(modes(pub), &covers_scene?(pub, &1, cast))
    end)
  end

  @doc """
  Would `mode` see nothing in this scene, even though somebody could?

  Distinct from unreadable: *Halden wasn't here* is a fact about the reader's current
  perspective and has a way out (switch, or carry on to the next scene), where *this
  one isn't shared* is a fact about the publication and doesn't.
  """
  @spec blank_for?(t(), mode(), [term()]) :: boolean()
  def blank_for?(%__MODULE__{} = pub, mode, cast),
    do: not covers_scene?(pub, mode, cast)

  # ── What a reader may take away (§3.1c) ──────────────────────────────────────

  @doc """
  May a reader carry this story on?

  Forking implies sheets: a fork must be able to continue the story and can't from
  prose alone. Note the design's own caveat — a "don't fork" flag on fully visible
  material is unenforceable, because anyone can retype it. What protects an artifact is
  not publishing it.
  """
  @spec forkable?(t()) :: boolean()
  def forkable?(%__MODULE__{forkable: f}), do: f

  @doc """
  Are character sheets exposed?

  Not a separate rung: they come with `forkable` and nothing else grants them. "You may
  read as Wren" and "you may read Wren's sheet" are different permissions — the sheet
  holds her concealed facts, her boundaries and her initial knowledge, which spoil
  *forward* rather than sideways.
  """
  @spec sheets?(t()) :: boolean()
  def sheets?(%__MODULE__{} = pub), do: forkable?(pub)

  @doc """
  How many of a story's people the reader doesn't get.

  Said plainly on the front page rather than implied by an absence: *two more people
  are in this and you don't get their side*. An unshared perspective is a deliberate
  authorial choice, and naming the count is what keeps it from reading as an omission.
  """
  @spec withheld(t(), [term()]) :: non_neg_integer()
  def withheld(%__MODULE__{perspectives: ids}, cast) do
    Enum.count(cast, &(to_string(&1) not in ids))
  end
end
