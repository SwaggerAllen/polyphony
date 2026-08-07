defmodule Polyphony.PurityCanaryTest do
  @moduledoc """
  The purity guards can still fail.

  Four tests in this suite assert that a computed set is empty — no `PolyphonyCore` module
  reaches an effect, no aggregate reaches a provider, no struct module reaches the repo, no
  screen reads. Each is a real invariant and each is checked the only way it can be, but
  they share a failure mode: **an analysis that has stopped seeing anything passes them
  all**, silently and permanently.

  That happened. `Polyphony.Test.Purity` did not treat a function capture as a call edge,
  so `Enum.map(ids, &Library.get/1)` in a screen was invisible to every guard above, for as
  long as they had existed. Nothing found it; somebody went looking.

  `Polyphony.Test.Canary` writes each evasion down as a function, and this asserts the
  analysis flags it. It is the half of the guard that fails when the guard breaks —
  and `pure/1` is the other direction, because an analysis that flags everything gets
  deleted rather than fixed.
  """
  use ExUnit.Case, async: true

  alias Polyphony.Test.{Canary, Purity}

  # Each entry names what would go unseen if the analysis lost this edge.
  @reads_the_database [
    {{Canary, :direct_read, 1}, "a direct repo call"},
    {{Canary, :read_via_helper, 1}, "a repo call one private helper away"},
    {{Canary, :read_two_hops, 1}, "a repo call two hops away — the closure must iterate"},
    {{Canary, :read_via_capture, 1}, "a repo call reached through &Mod.fun/1"},
    {{Canary, :read_via_unnameable_module, 2}, "a call on a module the walk cannot name"},
    {{Canary, :read_via_unnameable_capture, 2}, "a capture on a module the walk cannot name"}
  ]

  test "every way of reaching the database is seen" do
    impure = Purity.impure()

    for {mfa, what} <- @reads_the_database do
      assert MapSet.member?(impure, mfa), """
      #{inspect(mfa)} reaches the repo and the analysis says it doesn't.

      This canary stands for #{what}. Whatever edge stopped being followed, every guard
      built on `Polyphony.Test.Purity` is now passing for the wrong reason —
      `PolyphonyCoreTest`, `AggregatePurityTest`, `StructPurityTest` and `StorybookTest`
      are all asserting that a set is empty.
      """
    end
  end

  test "a provider call is seen at the provider floor" do
    assert MapSet.member?(Purity.reaches_llm(), {Canary, :call_provider, 1}),
           "the LLM floor no longer sees a provider call — invariant 2 is unguarded"
  end

  test "an effect that is not a database read is seen at the effects floor" do
    effects = Purity.reaches_effects()

    assert MapSet.member?(effects, {Canary, :broadcast_something, 2}),
           "broadcasting is not being counted as an effect"

    # And is genuinely a *wider* floor than the repo one — if the two sets have converged,
    # `PolyphonyCore`'s membership is being decided by the wrong question.
    refute MapSet.member?(Purity.impure(), {Canary, :broadcast_something, 2}),
           "broadcasting now counts as a database read — the two floors have collapsed"
  end

  test "a clock, a die and a fresh id are seen at the replay floor" do
    nondeterministic = Purity.reaches_nondeterminism()

    for {mfa, what} <- [
          {{Canary, :reads_the_clock, 0}, "reading the clock"},
          {{Canary, :rolls_a_die, 0}, "rolling a die"},
          {{Canary, :mints_an_id, 0}, "minting an id"}
        ] do
      assert MapSet.member?(nondeterministic, mfa), """
      #{what} is no longer counted against replay.

      None of these is an effect — they touch nothing and pass every other floor — and each
      one makes an event stream rebuild into something the log doesn't justify.
      """
    end
  end

  test "the replay floor stays MFA-precise, so the pure half of a module survives" do
    nondeterministic = Purity.reaches_nondeterminism()

    refute MapSet.member?(nondeterministic, {Canary, :pure_datetime, 2}),
           "DateTime.compare/2 is being counted as nondeterministic — the deny list has " <>
             "widened from functions to namespaces, and half the date handling in the app " <>
             "with it"
  end

  test "the database floor sees a changeset function that takes a repo" do
    # `Ecto.Changeset` is excused wholesale as a data library, which is right for all but
    # this one function — and getting it wrong is invisible, because the call looks like
    # every other validation on the pipeline.
    assert MapSet.member?(Purity.impure(), {Canary, :changeset_that_queries, 2}),
           "unsafe_validate_unique/4 no longer outranks the excuse for its namespace"

    refute MapSet.member?(Purity.impure(), {Canary, :pure_changeset, 1}),
           "building a changeset counts as a read again — that is 41 pure parsers back " <>
             "on the wrong side of every guard"
  end

  test "a pure function is clean at every floor" do
    # The direction that gets an over-eager guard deleted rather than fixed.
    for {name, set} <- [
          {"the repo floor", Purity.impure()},
          {"the effects floor", Purity.reaches_effects()},
          {"the provider floor", Purity.reaches_llm()},
          {"the replay floor", Purity.reaches_nondeterminism()}
        ] do
      refute MapSet.member?(set, {Canary, :pure, 1}),
             "#{name} flags a function that only calls Enum.map/2 — the analysis is over-broad"
    end
  end

  test "the canaries are all in the module, so this test can't pass by naming nothing" do
    exports = Canary.module_info(:exports)

    for {{_mod, fun, arity}, _what} <- @reads_the_database do
      assert {fun, arity} in exports,
             "Canary.#{fun}/#{arity} is gone — put it back or drop it here"
    end
  end
end
