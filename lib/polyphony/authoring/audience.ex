defmodule Polyphony.Authoring.Audience do
  @moduledoc """
  Who starts out knowing a secret (`ux/polyphony-audience-picker.html`).

  One shape, answering one question, on every surface that carries a secret: a
  character's fact, a world-bible entry, and whatever comes next. Getting it right
  once is why those surfaces cost nothing.

  ## Everything is an audience, including "everyone"

  An individual is an audience of one; common knowledge is the audience of all. So
  **secret is shorthand for *an audience narrower than everyone***, and the secret
  toggle is a one-tap route to the common case rather than a separate mechanism.

  That is why "everyone" is **not** a value here. It is the item's `concealed: false`
  state — ticking *Everyone* in the picker un-secrets the item. Storing it twice is
  how the two representations drift apart, which is the failure this component exists
  to avoid.

  ## Additive only, deliberately

  You cannot say *the whole Tidewatch except Marek*. Exceptions double the mental
  model and the case is rare enough to pay for by naming people instead. Everything
  here unions: a character listed directly, plus every character in a listed group.

  ## Groups are named, not expanded

  A group is stored as its id and resolved **when the question is asked**, never
  flattened at authoring time. This is the load-bearing decision: a walk-on written
  from the Tidewatch in scene 9 arrives already knowing, and nobody has to remember
  to assign anything.

  Its corollary is the rule that keeps it honest — **joining later doesn't
  backfill**. Membership is what resolution reads, so someone who joins the Tidewatch
  in scene 9 *does* resolve as knowing from then on. That is the same live-membership
  behaviour `Polyphony.Groups` describes, and the reason it isn't a contradiction is
  that the secret is only ever the **starting** point: what a character has actually
  learned during play is the event log's business, not this. Where the design says a
  late joiner "learns it in a scene", that is about `Groups.add_member/3` not seeding
  their sheet — it does not, and this doesn't either.

  ## An audience is belonging, never transit

  Being *in* a group — not having passed through it. A main cast member who walks
  into the undercroft doesn't absorb its secrets; the people who work there were born
  into them. That is why locations, when they exist, are a third kind of entry in the
  same list rather than a new mechanism.

  ## Whoever was there

  `scene: true` resolves to the cast of the scene the fact came from. It only means
  anything where there *is* such a scene, which is why it appears on **arc** entries
  and not on authored canon — a world's starting canon has no originating scene, and a
  row that can never resolve is worse than an absent one. Callers pass the members
  through `opts[:scene_members]`; without them it resolves to nobody, default-deny.

  ## What still isn't here

  **Locations.** *Anyone who's been to the Ninth Gate* is an audience like any other,
  and the design checked the shape against this component: it needs no change, because
  a location audience means **belonging** — the people who live and work there — not
  transit. It goes in the day locations do.
  """

  @derive Jason.Encoder
  defstruct group_ids: [], character_ids: [], scene: false

  @type t :: %__MODULE__{
          group_ids: [String.t()],
          character_ids: [String.t()],
          scene: boolean()
        }

  @doc "Nobody — the default, and usually the right answer."
  @spec empty() :: t()
  def empty, do: %__MODULE__{}

  @doc "Is this audience nobody at all? (Before resolution — a named group may be empty too.)"
  @spec empty?(t() | nil) :: boolean()
  def empty?(nil), do: true
  def empty?(%__MODULE__{group_ids: [], character_ids: [], scene: false}), do: true
  def empty?(%__MODULE__{}), do: false

  @doc """
  Coerce a stored or submitted value into an audience.

  `nil` is nobody, which is what every item written before audiences existed means —
  the default-deny reading, and the safe one.
  """
  @spec from(t() | map() | nil) :: t()
  def from(%__MODULE__{} = a), do: a
  def from(nil), do: empty()

  def from(%{} = m) do
    %__MODULE__{
      group_ids: ids(m["group_ids"] || m[:group_ids]),
      character_ids: ids(m["character_ids"] || m[:character_ids]),
      scene: (m["scene"] || m[:scene]) in [true, "true"]
    }
  end

  @doc "Toggle *whoever was there* — the cast of the scene the fact came from."
  @spec toggle_scene(t()) :: t()
  def toggle_scene(%__MODULE__{} = a), do: %__MODULE__{a | scene: not a.scene}

  defp ids(nil), do: []
  defp ids(list) when is_list(list), do: list |> Enum.map(&to_string/1) |> Enum.uniq()

  @doc "Add a character, order-preserving and idempotent."
  @spec add_character(t(), term()) :: t()
  def add_character(%__MODULE__{} = a, id),
    do: %__MODULE__{a | character_ids: append_unique(a.character_ids, id)}

  @doc "Remove a directly-named character. An inherited one is unaffected — take the group off."
  @spec remove_character(t(), term()) :: t()
  def remove_character(%__MODULE__{} = a, id),
    do: %__MODULE__{a | character_ids: List.delete(a.character_ids, to_string(id))}

  @doc "Add a group, order-preserving and idempotent."
  @spec add_group(t(), term()) :: t()
  def add_group(%__MODULE__{} = a, id),
    do: %__MODULE__{a | group_ids: append_unique(a.group_ids, id)}

  @doc "Remove a group. Everyone who was in it by inheritance alone stops knowing."
  @spec remove_group(t(), term()) :: t()
  def remove_group(%__MODULE__{} = a, id),
    do: %__MODULE__{a | group_ids: List.delete(a.group_ids, to_string(id))}

  @doc "Toggle a directly-named character on or off."
  @spec toggle_character(t(), term()) :: t()
  def toggle_character(%__MODULE__{} = a, id) do
    if to_string(id) in a.character_ids, do: remove_character(a, id), else: add_character(a, id)
  end

  @doc "Toggle a group on or off."
  @spec toggle_group(t(), term()) :: t()
  def toggle_group(%__MODULE__{} = a, id) do
    if to_string(id) in a.group_ids, do: remove_group(a, id), else: add_group(a, id)
  end

  @doc """
  The character ids named **directly**, as opposed to inherited from a group.

  What the picker draws as a solid tick rather than an outlined one: an inherited
  tick can't be individually removed, because the alternative is exceptions.
  """
  @spec named(t() | nil) :: [String.t()]
  def named(nil), do: []
  def named(%__MODULE__{character_ids: ids}), do: ids

  @doc """
  How the audience reads on the item's own line — *Secret · Aldous, Sable know*,
  *Secret · the Tidewatch, +1*, *Secret · nobody knows*.

  `label_for` renders one id (a name for a character, a name for a group). Groups are
  named rather than expanded, matching what the picker promises. Two or three fit;
  beyond that it becomes a count, because a line that wraps stops being scannable.
  """
  @spec summary(t() | nil, (String.t() -> String.t() | nil)) :: String.t()
  def summary(audience, label_for \\ fn id -> id end)
  def summary(nil, _label_for), do: "nobody knows"

  def summary(%__MODULE__{} = a, label_for) do
    scene_label = if a.scene, do: ["whoever was there"], else: []

    labels =
      scene_label ++
        for id <- a.group_ids ++ a.character_ids,
            label = label_for.(id),
            is_binary(label) and label != "",
            do: label

    case labels do
      [] -> "nobody knows"
      [one] -> "#{one} knows"
      [a1, b1] -> "#{a1}, #{b1} know"
      [a1, b1 | rest] -> "#{a1}, #{b1}, +#{length(rest)}"
    end
  end

  defp append_unique(ids, id) do
    id = to_string(id)
    if id in ids, do: ids, else: ids ++ [id]
  end
end
