defmodule Polyphony.StructPurityTest do
  @moduledoc """
  The struct modules stay struct modules.

  Each of these is a shape plus the pure helpers that go with it, and each had grown one
  or two functions that quietly went to the database — `Audience.resolve/2` expanding a
  group, `WorldBible.for_character/3` calling it, `Session.scene/3` reading a stream,
  `Cast.for_scene/1` reading another. Two names in a module that otherwise answers from
  data you already hold, and the module reads as pure right up until you call the wrong
  one.

  They are `Polyphony.Authoring.Knowledge`, `Polyphony.Reading.scene/3` and
  `Polyphony.Context.Rebuild.cast_for/1` now, and the callers compose. This is the check
  that keeps it that way, because the pressure to put the resolver back where it is
  convenient never goes away — `WorldBible.for_character/3` is a *nicer* call than
  `Knowledge.for_character/3`, and that is exactly why it ended up there.

  These modules are not in `PolyphonyCore`: they reference structs that live outside it
  (`TurnPacket`, `Snapshot`, `CharacterSheet`), so joining the layer is a further move
  with its own cost. Being pure and being in the core are different claims, and this one
  is the smaller of the two.
  """
  use ExUnit.Case, async: true

  alias Polyphony.Test.Purity

  @modules [
    Polyphony.Authoring.Audience,
    Polyphony.Authoring.WorldBible,
    Polyphony.Reading.Session,
    Polyphony.Scene.Cast
  ]

  test "none of them can reach an effect" do
    effects = Purity.reaches_effects()

    offenders =
      for mod <- @modules,
          {fun, arity} <- mod.module_info(:exports),
          fun not in [:module_info, :__info__, :__struct__, :behaviour_info],
          MapSet.member?(effects, {mod, fun, arity}),
          do: "#{inspect(mod)}.#{fun}/#{arity}"

    assert offenders == [], """
    These read, and they live on a module that otherwise doesn't:

    #{Enum.join(offenders, "\n")}

    A resolver on a struct module makes every other function on it look like a query.
    Put it where the reads are — `Polyphony.Authoring.Knowledge`, `Polyphony.Reading`, or
    `Polyphony.Context.Rebuild` — and let the caller compose the two, so the read is
    visible where it happens.
    """
  end

  test "the resolvers are where they were moved to, so this isn't pinning an empty set" do
    for {mod, fun, arity} <- [
          {Polyphony.Authoring.Knowledge, :resolve, 2},
          {Polyphony.Authoring.Knowledge, :knows?, 3},
          {Polyphony.Authoring.Knowledge, :for_character, 3},
          {Polyphony.Reading, :scene, 3},
          {Polyphony.Context.Rebuild, :cast_for, 1}
        ] do
      Code.ensure_loaded!(mod)

      assert function_exported?(mod, fun, arity),
             "#{inspect(mod)}.#{fun}/#{arity} is gone — did a resolver move back?"
    end
  end
end
