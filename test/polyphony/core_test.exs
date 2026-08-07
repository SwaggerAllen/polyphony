defmodule Polyphony.CoreTest do
  @moduledoc """
  `Polyphony.Core` is pure, computed rather than declared.

  The boundary declaration says what Core may *name*: the event vocabulary and the
  sheet's `Boundary` struct, and nothing else. That is enforced at compile time and it is
  most of the guarantee — but it is a statement about modules, and purity is a property of
  functions. A `Core` module could still grow `:erlang.now/0`, or reach an effect through
  a module it is already allowed to name.

  So this walks the call graph from every function in the namespace and holds it to the
  wider floor: the database and the event store, plus PubSub, mail, files, processes, ETS,
  `persistent_term` and the provider. That floor is the reason the membership list is what
  it is — under a repo-only floor `Broadcast`, `Mailer` and `DebugLog` all come out clean,
  and they publish, send mail and write ETS.

  The namespace is discovered, not listed. A module added to `Polyphony.Core.*` is held to
  this without anybody remembering to add it.
  """
  use ExUnit.Case, async: true

  alias Polyphony.Test.Purity

  defp core_modules do
    :code.all_available()
    |> Enum.map(fn {mod, _, _} -> to_string(mod) end)
    |> Enum.filter(&String.starts_with?(&1, "Elixir.Polyphony.Core"))
    |> Enum.map(&String.to_existing_atom/1)
    |> Enum.sort()
  end

  test "the namespace is not empty, so this test cannot pass by covering nothing" do
    assert length(core_modules()) >= 9,
           "found #{length(core_modules())} modules under Polyphony.Core — has it moved?"
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
    These are in Polyphony.Core and can reach an effect:

    #{Enum.join(offenders, "\n")}

    The core is data in, data out — it is what makes the visibility guarantee something
    you can reason about rather than something you hope holds. Whatever this function
    needs, the caller should have already resolved it.
    """
  end

  test "the visibility guarantee itself is in there, which is the point of the layer" do
    # Named rather than merely covered by the sweep above. Rule 3 is the invariant the
    # whole product rests on, and "it happens to live somewhere pure" is a weaker
    # statement than "it lives in the layer that cannot stop being pure".
    assert Polyphony.Core.Visibility in core_modules()
    assert Polyphony.Core.Packets in core_modules()
    assert Polyphony.Core.MembershipSet in core_modules()
  end
end
