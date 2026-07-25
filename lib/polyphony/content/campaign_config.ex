defmodule Polyphony.Content.CampaignConfig do
  @moduledoc """
  Layer 2 of content governance (§A5): the **per-campaign** content config.

  The author's `adult_content` master toggle gates three sub-toggles (sexual /
  graphic-violence / other). This shapes the generation register and sets the
  campaign's published content label. It is deliberately *not* per-character —
  that is the boundary layer (§A3), kept separate: layer 2 answers "is this
  content type enabled at all," layer 3 answers "does this character engage,
  in-fiction."

  `adult_content: false` (the default) forces an empty register no matter what the
  sub-toggles hold — the master toggle is the campaign ceiling.
  """
  @derive Jason.Encoder
  defstruct adult_content: false, sexual: false, graphic_violence: false, other: false

  @type t :: %__MODULE__{
          adult_content: boolean(),
          sexual: boolean(),
          graphic_violence: boolean(),
          other: boolean()
        }

  @doc """
  The categories this campaign turns on — empty unless `adult_content` is set, so
  the master toggle gates every sub-toggle. The field names match the category
  atoms exactly (`Polyphony.Content.categories/0`).
  """
  @spec enabled(t()) :: [Polyphony.Content.category()]
  def enabled(%__MODULE__{adult_content: false}), do: []

  def enabled(%__MODULE__{} = config),
    do: Enum.filter(Polyphony.Content.categories(), &Map.get(config, &1))
end
