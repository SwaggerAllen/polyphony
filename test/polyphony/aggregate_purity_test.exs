defmodule Polyphony.AggregatePurityTest do
  @moduledoc """
  Invariant 2, computed: **no LLM and no I/O in an aggregate**.

  Commanded replays aggregates. A generation inside `execute/2` re-fires every time the
  stream is rebuilt — which is not a slow path or a duplicate charge but a *different
  story each time*, since a provider call is not deterministic. A read is the same
  problem one step quieter: the aggregate would decide from data that has moved since the
  events were written, and replay would produce a state the log doesn't justify.

  Until this test existed the invariant rested on somebody noticing in review. It reuses
  the call-graph walk the screens guard is built on, seeded at two different floors: the
  repo/event-store, and the provider.

  Aggregates are listed by name rather than discovered. `use Commanded.Aggregate` leaves
  no marker to detect, and a guessed list that silently matches nothing is worse than no
  test — so the list is explicit and `every aggregate is listed` fails when a module
  grows `execute/2` and nobody adds it here.
  """
  use ExUnit.Case, async: true

  alias Polyphony.Test.Purity

  @aggregates [Polyphony.Scene, PolyphonyCore.Director.Beat]

  defp callbacks(module) do
    module.module_info(:exports)
    |> Enum.filter(fn {name, arity} -> {name, arity} in [{:execute, 2}, {:apply, 2}] end)
    |> Enum.map(fn {name, arity} -> {module, name, arity} end)
  end

  test "an aggregate cannot reach the database or the event store" do
    impure = Purity.impure()

    for aggregate <- @aggregates, mfa <- callbacks(aggregate) do
      refute MapSet.member?(impure, mfa),
             "#{inspect(mfa)} can reach the repo or the event store. Aggregates are replayed, " <>
               "so a read here decides from data that has moved since the events were written. " <>
               "Do it in the job that produces the command."
    end
  end

  test "an aggregate cannot reach a provider" do
    llm = Purity.reaches_llm()

    for aggregate <- @aggregates, mfa <- callbacks(aggregate) do
      refute MapSet.member?(llm, mfa),
             "#{inspect(mfa)} can reach an LLM provider. Replay would re-run it, and a " <>
               "generation is not deterministic — the same log would rebuild into a " <>
               "different story. Generate in an Oban job and dispatch a command."
    end
  end

  test "every aggregate is listed, so this test can't quietly cover nothing" do
    found =
      :code.all_available()
      |> Enum.map(fn {mod, _, _} -> to_string(mod) end)
      |> Enum.filter(
        &(String.starts_with?(&1, "Elixir.Polyphony.") or
            String.starts_with?(&1, "Elixir.PolyphonyCore."))
      )
      |> Enum.map(&String.to_existing_atom/1)
      |> Enum.filter(fn mod ->
        Code.ensure_loaded?(mod) and function_exported?(mod, :execute, 2) and
          function_exported?(mod, :apply, 2)
      end)

    assert Enum.sort(found) == Enum.sort(@aggregates), """
    The set of modules with both `execute/2` and `apply/2` is not the list this test checks.

    Not listed: #{inspect(found -- @aggregates)}
    Listed but gone: #{inspect(@aggregates -- found)}

    If a new module is an aggregate, add it to @aggregates. If it merely happens to have
    both callbacks, say so here — silently is how the invariant stops being checked.
    """
  end

  test "each aggregate really does have the callbacks, so the checks above aren't vacuous" do
    for aggregate <- @aggregates do
      assert callbacks(aggregate) != [],
             "#{inspect(aggregate)} exports neither execute/2 nor apply/2 — has it moved?"
    end
  end
end
