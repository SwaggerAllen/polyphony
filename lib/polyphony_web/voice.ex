defmodule PolyphonyWeb.Voice do
  @moduledoc """
  Voice colours — the per-character hue the design kit assigns by cast order.

  The kit defines eight (`--v1`…`--v8`) and states the rule that makes them
  useful: *the same character is the same hue in the transcript, the status
  strip, the cast list, the picker and their sheet* (`ux/README.md`, porting
  notes). So the colour is never chosen by an author and never derived from the
  character's name — it's a position in a cast list, which is why this module
  takes an ordered list of ids and hands back an assignment every surface can
  share.

  Past eight it wraps: the kit says so explicitly, and a wrapped hue is a much
  smaller problem than an unstyled character.

  Colours are emitted as `var(--vN)` so they resolve against whichever register
  and theme the surrounding `.fr` frame is in — the kit redefines all eight per
  register/theme, and this module must not pin a hex value.
  """

  @count 8

  @typedoc "Ordered cast → voice-colour assignment. Keys are character ids."
  @type t :: %{optional(String.t()) => String.t()}

  @doc """
  Assign voice colours to an ordered cast.

  The order is the cast order, and it is the caller's job to keep it stable —
  for a scene that's entry order, for a campaign the campaign's own list.
  Duplicates keep their first position, so re-entry doesn't reshuffle the cast.

      iex> PolyphonyWeb.Voice.assign(["wren", "ilias"])
      %{"wren" => "var(--v1)", "ilias" => "var(--v2)"}
  """
  @spec assign([String.t()]) :: t()
  def assign(ids) when is_list(ids) do
    ids
    |> Enum.uniq()
    |> Enum.with_index()
    |> Map.new(fn {id, i} -> {id, nth(i)} end)
  end

  @doc """
  The colour for `id`, or the neutral base colour when it has no voice.

  Anything that isn't a cast member — the Director, a system line, a character
  the viewer can't see — takes `--bc`, the register's plain foreground. That
  keeps "no voice" visually distinct from every voice rather than borrowing one.
  """
  @spec of(t(), String.t() | nil) :: String.t()
  def of(_voices, nil), do: neutral()
  def of(voices, id), do: Map.get(voices, id, neutral())

  @doc "The colour used where there is no voice: the register's foreground."
  @spec neutral() :: String.t()
  def neutral, do: "var(--bc)"

  @doc """
  The `style` attribute value that hands a voice colour to a kit component.

  Kit components read `--vc` (the perspective control, interior monologue) or
  `--sc` (status-strip slots, switches); both are set the same way, so this
  builds the declaration rather than leaving each call site to string-build it.

      iex> PolyphonyWeb.Voice.var("--vc", "var(--v1)")
      "--vc:var(--v1)"
  """
  @spec var(String.t(), String.t()) :: String.t()
  def var(name, colour), do: "#{name}:#{colour}"

  @doc "How many distinct voices the kit defines before wrapping."
  @spec count() :: pos_integer()
  def count, do: @count

  defp nth(i), do: "var(--v#{rem(i, @count) + 1})"
end
