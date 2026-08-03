defmodule PolyphonyWeb.Voice do
  @moduledoc """
  Voice colours — the per-character hue the design kit gives each character.

  The kit defines eight (`--v1`…`--v8`) and states the rule that makes them
  useful: *the same character is the same hue in the transcript, the status
  strip, the cast list, the picker and their sheet* (`ux/README.md`, porting
  notes).

  The hue is **stored on the character sheet**, assigned once at creation
  (`Polyphony.Library.put/2`). It was briefly derived from position in a cast
  instead, which satisfies the rule only until somebody is removed — then everyone
  after them changes colour, including in transcripts they already appear in.
  Storing it also leaves room for an author to choose their own later.

  So this module doesn't assign anything. It turns a stored hue into the CSS the
  kit expects, and wraps past eight because the kit says to — a wrapped hue is a
  much smaller problem than an unstyled character.

  Colours are emitted as `var(--vN)` so they resolve against whichever register
  and theme the surrounding `.fr` frame is in — the kit redefines all eight per
  register/theme, and this module must not pin a hex value.
  """

  @count Polyphony.Authoring.CharacterSheet.hue_count()

  @typedoc "Ordered cast → voice-colour assignment. Keys are character ids."
  @type t :: %{optional(String.t()) => String.t()}

  @doc """
  The CSS colour for a stored hue.

  Nil — a sheet written before hues existed, or none at all — takes the register's
  plain foreground rather than borrowing somebody's colour.

      iex> PolyphonyWeb.Voice.colour(1)
      "var(--v1)"
  """
  @spec colour(integer() | nil) :: String.t()
  def colour(nil), do: neutral()

  def colour(hue) when is_integer(hue),
    do: "var(--v#{rem(max(hue, 1) - 1, @count) + 1})"

  @doc "The colour for a character sheet, from the hue stored on it."
  @spec of_sheet(term()) :: String.t()
  def of_sheet(%{hue: hue}), do: colour(hue)
  def of_sheet(_), do: neutral()

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
end
