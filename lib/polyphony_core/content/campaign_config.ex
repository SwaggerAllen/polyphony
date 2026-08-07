defmodule PolyphonyCore.Content.CampaignConfig do
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
  atoms exactly (`PolyphonyCore.Content.categories/0`).
  """
  @spec enabled(t()) :: [PolyphonyCore.Content.category()]
  def enabled(%__MODULE__{adult_content: false}), do: []

  def enabled(%__MODULE__{} = config),
    do: Enum.filter(PolyphonyCore.Content.categories(), &Map.get(config, &1))

  @doc """
  Pull a config out of a campaign `Library` payload's `:content_config` field,
  defaulting to the all-off config for a campaign that predates the setting (or one
  stored as a plain map). The single source of truth every wiring point resolves from.
  """
  @spec from_payload(map() | any()) :: t()
  def from_payload(%{content_config: %__MODULE__{} = config}), do: config

  def from_payload(%{content_config: %{} = m}) do
    %__MODULE__{
      adult_content: !!(m[:adult_content] || m["adult_content"]),
      sexual: !!(m[:sexual] || m["sexual"]),
      graphic_violence: !!(m[:graphic_violence] || m["graphic_violence"]),
      other: !!(m[:other] || m["other"])
    }
  end

  def from_payload(_), do: %__MODULE__{}

  @doc """
  The config as the plain map a `Library` payload stores.

  A payload is written to a `:binary` column as an Erlang term (`PolyphonyCore.Blob`),
  which spells a struct's module out as an atom — so storing `%CampaignConfig{}` would put
  this module's path in the row and a later rename would take the campaign's whole payload
  down with it. A map has no module in it and cannot be broken that way; `from_payload/1`
  has always read one.
  """
  @spec to_payload(t()) :: %{
          adult_content: boolean(),
          sexual: boolean(),
          graphic_violence: boolean(),
          other: boolean()
        }
  def to_payload(%__MODULE__{} = config), do: Map.from_struct(config)

  @doc "A short human label for the campaign's maturity, for the published snapshot."
  @spec label(t()) :: String.t()
  def label(%__MODULE__{} = config) do
    case enabled(config) do
      [] -> "No adult content"
      cats -> "Adult content: " <> Enum.map_join(cats, ", ", &category_label/1)
    end
  end

  defp category_label(:sexual), do: "sexual"
  defp category_label(:graphic_violence), do: "graphic violence"
  defp category_label(:other), do: "other mature themes"
end
