defmodule PolyphonyCoreTest do
  @moduledoc """
  `PolyphonyCore` is pure, computed rather than declared.

  The boundary declaration is `deps: []` — Core may name nothing outside itself, and that
  is enforced at compile time. It is most of the guarantee, but it is a statement about
  *modules*, and purity is a property of *functions*: a Core module can still reach an
  effect through the standard library, or through a sibling it is perfectly entitled to
  call.

  So this walks the call graph from every function in the namespace and holds it to two
  floors. The **effects** floor is the database and the event store, plus PubSub, mail,
  files, processes, ETS, `persistent_term` and the provider — and that width is the reason
  the membership list is what it is, because under a repo-only floor `Broadcast`, `Mailer`
  and `DebugLog` all come out clean while publishing, sending mail and writing ETS. The
  **replay** floor is clocks, randomness and fresh ids, which are not effects at all: they
  touch nothing, pass every test above, and still make a stream rebuild into a different
  story than the one the log records.

  The namespace is discovered, not listed. A module added to `PolyphonyCore.*` is held to
  this without anybody remembering to add it.
  """
  use ExUnit.Case, async: true

  alias Polyphony.Test.Purity

  defp core_modules do
    :code.all_available()
    |> Enum.map(fn {mod, _, _} -> to_string(mod) end)
    |> Enum.filter(&String.starts_with?(&1, "Elixir.PolyphonyCore"))
    |> Enum.map(&String.to_existing_atom/1)
    |> Enum.sort()
  end

  test "the namespace is not empty, so this test cannot pass by covering nothing" do
    assert length(core_modules()) >= 30,
           "found #{length(core_modules())} modules under PolyphonyCore — has it moved?"
  end

  test "nothing in the core can reach an effect" do
    effects = Purity.reaches_effects()

    offenders =
      for mod <- core_modules(),
          {fun, arity} <- mod.module_info(:exports),
          fun not in [:module_info, :__info__, :__struct__, :behaviour_info],
          MapSet.member?(effects, {mod, fun, arity}),
          do: "#{inspect(mod)}.#{fun}/#{arity}"

    assert offenders == [], """
    These are in PolyphonyCore and can reach an effect:

    #{Enum.join(offenders, "\n")}

    The core is data in, data out — it is what makes the visibility guarantee something
    you can reason about rather than something you hope holds. Whatever this function
    needs, the caller should have already resolved it.
    """
  end

  test "nothing in the core can read a clock, roll a die or mint an id" do
    nondeterministic = Purity.reaches_nondeterminism()

    offenders =
      for mod <- core_modules(),
          {fun, arity} <- mod.module_info(:exports),
          fun not in [:module_info, :__info__, :__struct__, :behaviour_info],
          MapSet.member?(nondeterministic, {mod, fun, arity}),
          do: "#{inspect(mod)}.#{fun}/#{arity}"

    assert offenders == [], """
    These are in PolyphonyCore and are not deterministic:

    #{Enum.join(offenders, "\n")}

    The core answers from the log, and the log is replayed. A function here that reads the
    clock answers one way now and another way on the rebuild — which for `Visibility`
    means a character's projection is not a property of the events but of when you asked.
    Whatever this needs, the caller should have stamped it and passed it in.
    """
  end

  test "the visibility guarantee itself is in there, which is the point of the layer" do
    # Named rather than merely covered by the sweep above. Rule 3 is the invariant the
    # whole product rests on, and "it happens to live somewhere pure" is a weaker
    # statement than "it lives in the layer that cannot stop being pure".
    assert PolyphonyCore.Visibility in core_modules()
    assert PolyphonyCore.Packets in core_modules()
    assert PolyphonyCore.MembershipSet in core_modules()
  end
end
