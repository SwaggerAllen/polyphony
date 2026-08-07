defmodule Polyphony.Core.Blob do
  @moduledoc """
  Storing a term in a `:binary` column, and reading it back safely.

  Five tables keep an opaque term rather than columns, for the same reason each time:
  the value is a domain struct nobody queries — a library payload, a pending packet, an
  audience, a build's arguments, a generation's request and result. Splitting any of
  them into columns would buy nothing and cost a migration every time the struct grows
  a field.

  ## Why one module

  Each of those five had its own private `encode/1` and `decode/1`, and each carried the
  same six-line Sobelow incantation to say so. That is a bad thing to have five copies
  of — not because it's long, but because it's a **security decision**. `binary_to_term`
  without `:safe` will fabricate atoms and module references out of whatever is in the
  binary; `:safe` is what makes reading a stored term merely a deserialisation rather
  than a way to reach into the VM. Five copies is five chances for the sixth to be
  written without it, and the annotation that silences the scanner would be copied along
  with the mistake.

  So the guarantee lives here, once, where a test can hold it. Callers say `Blob.encode`
  and `Blob.decode` and never touch `:erlang` at all.

  ## What it is not

  Not a general serialisation layer, and not for anything that crosses a trust boundary.
  Erlang term format is only safe to read when *we* wrote it: `:safe` stops the atom
  table from being filled, but a binary from outside is still an attacker choosing the
  shape of a struct the code will then pattern-match. Everything decoded here came from
  a column this application wrote.
  """

  @doc "A term, as bytes for a `:binary` column. `nil` stays `nil`."
  @spec encode(term()) :: binary() | nil
  def encode(nil), do: nil
  def encode(term), do: :erlang.term_to_binary(term)

  @doc """
  Bytes from one of our own columns, back to the term.

  `:safe` is not optional and is the whole reason this function exists — see the
  moduledoc.
  """
  @spec decode(binary() | nil) :: term()
  def decode(nil), do: nil

  # Registered because the attribute is read by Sobelow, not the compiler, which would
  # otherwise warn it is set and never used (and CI compiles as errors). This is now the
  # only `binary_to_term` in the application, so it is also the only annotation.
  Module.register_attribute(__MODULE__, :sobelow_skip, accumulate: true)
  @sobelow_skip ["Misc.BinToTerm"]
  def decode(bin) when is_binary(bin), do: :erlang.binary_to_term(bin, [:safe])
end
