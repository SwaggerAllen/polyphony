defmodule Polyphony.Authoring.WorldBible do
  @moduledoc """
  The authored, portable world layer (§6.7): setting, tone, and **rules/physics**.

  Rules go into *every* character's stable prefix — cheap, and they keep
  generation from contradicting the setting (§6.7). Because the bible is authored
  and rarely changes, it sits at the very top of the cached prefix (refresh:
  never, §9).
  """
  @derive Jason.Encoder
  defstruct name: nil,
            # The outward blurb — the only part strangers see before they take this
            # world. Written from everything below it, secrets included, under
            # instruction to give none of them away (§2.12).
            cover: nil,
            setting: nil,
            tone: nil,
            rules: [],
            starting_canon: []

  @type t :: %__MODULE__{
          name: String.t() | nil,
          setting: String.t() | nil,
          tone: String.t() | nil,
          rules: [String.t()],
          starting_canon: [String.t()]
        }
end
