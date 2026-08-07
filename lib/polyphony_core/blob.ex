defmodule PolyphonyCore.Blob do
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

  ## A struct in a blob makes its module path stored data

  Erlang term format writes a struct's module as an atom — its full name, in bytes. So
  `%PolyphonyCore.Publication{}` in a payload puts `Elixir.PolyphonyCore.Publication` in
  the column, and **renaming the module orphans every row already written**. Worse than
  orphans: `:safe` refuses to *create* the missing atom, so the decode raises `ArgumentError`
  and takes the whole payload with it — a campaign's name and premise are lost along with
  the struct that moved. On a running node the atom is usually still around from some
  other reference and the bug hides; on the next deploy's fresh BEAM it is not, and every
  affected row fails at once.

  This is the same defect as storing module names as event types (see
  `PolyphonyCore.Events.TypeProvider`), and it needs the same two answers.

  Going forward: **prefer a plain map** for anything whose reader already tolerates one
  (`CampaignConfig.from_payload/1`, `Publication.from/1`), because a map carries no module
  path at all and cannot be broken by a rename.

  For what is already written: `@renames` maps every name this application has stored a
  struct under to the module that answers to it now. Naming a legacy module as a literal
  atom here is load-bearing twice over — it records the rename *and* puts the atom in this
  module's atom table, which is the only reason `:safe` can read the row at all. Entries
  are permanent; the rows they rescue are immutable, and nothing but this list remembers
  they exist.
  """

  # Every name a struct in one of our columns has been stored under, and what answers to
  # it now. Write the legacy side as a literal atom — `:"Elixir.…"` — never as an alias,
  # so it survives the module being deleted and lands in this module's atom table.
  @renames %{
    :"Elixir.Polyphony.Publication" => PolyphonyCore.Publication,
    :"Elixir.Polyphony.Core.Publication" => PolyphonyCore.Publication,
    :"Elixir.Polyphony.Content.CampaignConfig" => PolyphonyCore.Content.CampaignConfig,
    :"Elixir.Polyphony.Core.Content.CampaignConfig" => PolyphonyCore.Content.CampaignConfig,

    # A pending user packet is a whole `TurnPacket` in `packet_drafts.packet` — the moves
    # and the self-state with it — so all three names moved when the aggregate did.
    :"Elixir.Polyphony.TurnPacket" => PolyphonyCore.TurnPacket,
    :"Elixir.Polyphony.TurnPacket.Move" => PolyphonyCore.TurnPacket.Move,
    :"Elixir.Polyphony.TurnPacket.SelfState" => PolyphonyCore.TurnPacket.SelfState
    #
    # `Scene.Cast` moved in the same commit and is deliberately **not** here: it lives on
    # a `SceneContext`, which only ever reaches `Context.Store` — ETS, holding live terms,
    # wiped on restart and never serialized. An entry for it would be a guess, and a table
    # of guesses is one nobody can audit against what is actually in a column.
  }

  @legacy_names Enum.map(@renames, fn {old, _} -> Atom.to_string(old) end)

  @doc """
  The rename table, as `%{legacy_module_atom => current_module}`. Public so a test can
  round-trip a blob written under each old name rather than trusting the list by eye.
  """
  @spec renames() :: %{atom() => module()}
  def renames, do: @renames

  @doc "A term, as bytes for a `:binary` column. `nil` stays `nil`."
  @spec encode(term()) :: binary() | nil
  def encode(nil), do: nil
  def encode(term), do: :erlang.term_to_binary(term)

  @doc """
  Bytes from one of our own columns, back to the term.

  `:safe` is not optional and is the whole reason this function exists — see the
  moduledoc.

  A blob holding a struct under a name from `@renames` is rebuilt into the module that
  answers to it now, field by field, so a field the struct has since dropped is discarded
  and one it has since gained takes its default. That is `Kernel.struct/2`'s behaviour and
  it is the forgiving one on purpose: a stored term is history, and history is allowed to
  be the wrong shape.
  """
  @spec decode(binary() | nil) :: term()
  def decode(nil), do: nil

  # Registered because the attribute is read by Sobelow, not the compiler, which would
  # otherwise warn it is set and never used (and CI compiles as errors). This is now the
  # only `binary_to_term` in the application, so it is also the only annotation.
  Module.register_attribute(__MODULE__, :sobelow_skip, accumulate: true)
  @sobelow_skip ["Misc.BinToTerm"]
  def decode(bin) when is_binary(bin) do
    term = :erlang.binary_to_term(bin, [:safe])

    # ETF spells an atom out in bytes, so the cheap question — is any legacy name in here
    # at all — is answerable without walking the term. Nearly every blob says no, and pays
    # one scan rather than a full rebuild.
    if :binary.match(bin, @legacy_names) == :nomatch, do: term, else: restore(term)
  end

  defp restore(%{__struct__: module} = term) do
    fields = term |> Map.delete(:__struct__) |> Map.new(fn {k, v} -> {k, restore(v)} end)

    struct(Map.get(@renames, module, module), fields)
  end

  defp restore(%{} = term), do: Map.new(term, fn {k, v} -> {restore(k), restore(v)} end)
  defp restore(term) when is_list(term), do: Enum.map(term, &restore/1)

  defp restore(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.map(&restore/1) |> List.to_tuple()

  defp restore(term), do: term
end
