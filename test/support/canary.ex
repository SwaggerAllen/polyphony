defmodule Polyphony.Test.Canary do
  @moduledoc """
  Deliberately impure functions, so the purity guards can be shown to fail.

  Every guard built on `Polyphony.Test.Purity` — `PolyphonyCoreTest`,
  `Polyphony.AggregatePurityTest`, `Polyphony.StructPurityTest`, `PolyphonyWeb.StorybookTest`
  — asserts that a set comes back **empty**. A test shaped like that passes just as
  happily when the analysis has stopped seeing anything at all, and that is not
  hypothetical: the walk missed function captures for its entire life, so a screen could
  reach the repo through `Enum.map(ids, &Library.get/1)` and every one of those guards
  stayed green. It was found by hand, by writing that line into a screen and watching
  nothing happen.

  So each way the walk can be evaded gets a function here, and `Polyphony.PurityCanaryTest`
  asserts the analysis flags it. The functions are never called — `Purity` reads abstract
  code, so being compiled is the whole of their job. They live under `Polyphony.*` because
  that is the tree the walk covers; nothing calls them, so they cannot contaminate anyone
  else's answer.

  The negative control matters as much as the positive ones: `pure/1` must come back clean.
  A guard that flags everything is broken in the direction that gets it deleted.
  """

  alias Polyphony.Library
  alias Polyphony.Repo

  @doc "Reads directly. The simplest thing the walk has to see."
  def direct_read(id), do: Repo.get(Library, id)

  @doc "Reads through a private helper — the fixpoint closure, not the seeding."
  def read_via_helper(id), do: helper(id)

  defp helper(id), do: Repo.get(Library, id)

  @doc "Reads two modules deep, so the closure has to iterate rather than take one step."
  def read_two_hops(id), do: read_via_helper(id)

  @doc """
  Reads through a **capture**. This is the one that was actually missed: `&Mod.fun/1` is
  not a `:call` node, so the walk descended into it as an anonymous tuple and came back
  with nothing.
  """
  def read_via_capture(ids), do: Enum.map(ids, &Library.get/1)

  @doc """
  Calls a module the walk cannot name. Treated as a read on purpose — the repo is
  injectable across the domain (`repo(opts).all(q)`), so reading these as "unknown,
  therefore fine" declared `Library.get/1` pure the first time this analysis ran.
  """
  def read_via_unnameable_module(mod, id), do: mod.get(id)

  @doc "The same evasion with a capture: `&mod.fun/1`, module in a variable."
  def read_via_unnameable_capture(mod, ids), do: Enum.map(ids, &mod.get/1)

  @doc "Reaches a provider — the floor `AggregatePurityTest` uses, which is not the repo."
  def call_provider(messages), do: Polyphony.LLM.call(messages, [])

  @doc """
  Reaches an effect that is **not** a database read: broadcasting. This is the floor that
  decides `PolyphonyCore`'s membership, and under a repo-only floor it scores clean.
  """
  def broadcast_something(topic, message),
    do: Phoenix.PubSub.broadcast(Polyphony.PubSub, topic, message)

  @doc """
  Reads the clock. Not an effect by any ordinary test — it touches nothing outside the
  process — and it is what makes a stream unreplayable, which is what the log is for.
  """
  def reads_the_clock, do: DateTime.utc_now()

  @doc "Rolls a die. The other half of the replay floor."
  def rolls_a_die, do: :rand.uniform(6)

  @doc "Mints an id, which is the same problem wearing a third hat."
  def mints_an_id, do: Ecto.UUID.generate()

  @doc """
  Queries through `Ecto.Changeset`, which is otherwise excused as a data library. If the
  MFA-level deny stops outranking the namespace-level excuse, this goes quiet.
  """
  def changeset_that_queries(changeset, repo),
    do: Ecto.Changeset.unsafe_validate_unique(changeset, [:email], repo)

  @doc """
  Builds a changeset and nothing else. Must come back **clean** — calling this a read is
  what put every schema parser in the app on the impure side.
  """
  def pure_changeset(changeset), do: Ecto.Changeset.validate_required(changeset, [:name])

  @doc """
  Compares two timestamps. Must come back clean at the replay floor: the deny list is
  MFA-level precisely so `DateTime.compare/2` stays usable while `DateTime.utc_now/0`
  does not.
  """
  def pure_datetime(a, b), do: DateTime.compare(a, b)

  @doc """
  The negative control. Data in, data out, calling only `Enum` — it must come back clean
  from every floor, or the guards are passing on noise rather than on purity.
  """
  def pure(list), do: Enum.map(list, fn x -> x * 2 end)
end
