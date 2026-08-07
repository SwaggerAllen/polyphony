defmodule Polyphony.Core.Content do
  @moduledoc """
  Content governance as **three nested layers** (§A5), not one flat flag:

    1. **App-wide 18+ floor** (`Polyphony.Core.Content.Floor`) — non-configurable; the
       widest ceiling, a property of the account (18+ attestation, A9/B2). Adult
       categories exist at all only because the account cleared this floor.
    2. **Per-campaign content config** (`Polyphony.Core.Content.CampaignConfig`) — the
       author's `adult_content` master toggle plus per-category sub-toggles. Shapes
       the generation register and the published content label.
    3. **Per-character boundaries** (§A3, `CharacterSheet.Boundary`) —
       characterization *within* what the campaign allows.

  ## The nesting invariant

  A narrower layer restricts within a broader one and **never expands past it**.
  The effective register is an intersection, computed outermost-in:

      effective = floor ∩ campaign_enabled

  so campaign config off ⇒ no adult content regardless of any `:open` boundary, and
  a boundary can only ever *narrow* an already-enabled category, never open one the
  campaign (or the floor) disabled. This is enforced twice: as an authoring-time
  validation (`constrain_boundary/2`, FS §V8a) and as a context-assembly input —
  the register is rendered into what the Director and characters are told, and it
  caps boundary resolution (`gate_boundary/2`).

  Layers 2 and 3 are kept **conceptually separate**: layer 2 answers "is this
  content type enabled at all," layer 3 answers "does this character engage,
  in-fiction." A boundary's optional `:category` is only the link that lets the
  ceiling cap it — a pure-characterization boundary (`category: nil`, e.g. betrayal
  or discussing family) is never touched by the register.
  """

  alias Polyphony.Authoring.CharacterSheet.Boundary
  alias Polyphony.Core.Content.{CampaignConfig, Floor}

  @type category :: :sexual | :graphic_violence | :other

  @categories [:sexual, :graphic_violence, :other]

  @doc "The adult-content categories the governance layers recognize."
  @spec categories() :: [category()]
  def categories, do: @categories

  @doc """
  The **effective register**: the adult categories actually permitted, `floor ∩
  campaign_enabled`. Empty (the default) means no adult content at all. `opts` are
  forwarded to `Floor.register/1` (e.g. `attested:`).
  """
  @spec register(CampaignConfig.t(), keyword()) :: [category()]
  def register(%CampaignConfig{} = config, opts \\ []) do
    floor = Floor.register(opts)
    for c <- CampaignConfig.enabled(config), c in floor, do: c
  end

  @doc "Does `register` permit `category`? `nil` (pure characterization) always passes."
  @spec permits?([category()], category() | nil) :: boolean()
  def permits?(_register, nil), do: true
  def permits?(register, category), do: category in register

  @doc """
  Cap a boundary by the register (layer 2 constrains layer 3). One whose `:category`
  the register disables is **capped toward refusal** — the campaign ceiling overrides
  characterization, so an `:open` stance can't reopen disabled content. One with no
  category is characterization and passes through untouched.

  **Toward refusal, not merely `:closed`.** For a refusal those are the same thing:
  forced closed means she won't. For a **compulsion** they are opposites — a closed
  compulsion is one she always acts on — so capping it also flips its direction, and
  the item becomes a hard line against the same topic. `ux/polyphony-character.html`
  §05 states the rule and why: *a compulsion flagged for content the campaign doesn't
  allow is held closed, meaning she doesn't do it. That's the correct direction to
  fail in.* A cap that only set `stance: :closed` would make the ceiling compel the
  content it exists to forbid.

  Applied at context assembly, before `BoundaryGate.resolve/3`, so a gated-off
  category never releases regardless of arc or stance.
  """
  @spec gate_boundary(Boundary.t(), [category()]) :: Boundary.t()
  def gate_boundary(%Boundary{category: category} = boundary, register) do
    if permits?(register, category), do: boundary, else: cap(boundary)
  end

  @doc """
  Authoring-time constraint (FS §V8a): the same rule surfaced for the boundary
  editor. Returns `{:ok, boundary}` when the category is permitted, or
  `{:constrained, capped}` when the campaign ceiling forbids it — the editor must not
  let an author open a boundary past the ceiling. Caps identically to
  `gate_boundary/2`, direction included.
  """
  @spec constrain_boundary(Boundary.t(), [category()]) ::
          {:ok, Boundary.t()} | {:constrained, Boundary.t()}
  def constrain_boundary(%Boundary{category: category} = boundary, register) do
    if permits?(register, category),
      do: {:ok, boundary},
      else: {:constrained, cap(boundary)}
  end

  # Held, and held as a refusal — so the capped item always means "they don't".
  defp cap(%Boundary{} = boundary),
    do: %Boundary{boundary | stance: :closed, direction: :refusal}

  @doc """
  Render the enabled register for the prefix — what the Director and characters are
  told the scene permits. Returns `nil` for the empty (ordinary-limits) register,
  which needs no announcement; the model already assumes it.
  """
  @spec render_register([category()]) :: String.t() | nil
  def render_register([]), do: nil

  def render_register(register) do
    "Content register enabled for this scene: " <>
      (register |> Enum.map(&label/1) |> Enum.join(", ")) <>
      ". This sets what content is permitted at all; a character's own boundaries " <>
      "still govern whether they engage."
  end

  @doc "Normalize a list of strings/atoms to known category atoms, dropping the rest."
  @spec cast_categories([category() | String.t()]) :: [category()]
  def cast_categories(values) when is_list(values) do
    for v <- values, cat = to_category(v), do: cat
  end

  def cast_categories(_), do: []

  defp to_category(v) when v in @categories, do: v
  defp to_category(v) when is_binary(v), do: Enum.find(@categories, &(to_string(&1) == v))
  defp to_category(_), do: nil

  defp label(:sexual), do: "explicit sexual content"
  defp label(:graphic_violence), do: "graphic violence"
  defp label(:other), do: "other mature themes"
end
