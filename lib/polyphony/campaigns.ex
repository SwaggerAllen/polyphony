defmodule Polyphony.Campaigns do
  @moduledoc """
  Campaigns as library entries: their lifecycle, and the reads the library's rows need
  (`ux/polyphony-library.html`).

  Sits beside `Polyphony.Characters` and `Polyphony.Groups` for the same reason —
  storage, ownership, archiving and versioning are `Polyphony.Library`'s job, and only
  what is specific to campaigns lives here.

  ## Finishing is not archiving (§2.5c)

  Two different things, deliberately kept apart:

    * **Archived** — filing. Out of the default lists, reversible, and carrying no
      meaning about the story. `Library.archive/2`.
    * **Finished** — a statement. The campaign is a concluded whole. It is the
      precondition for another campaign naming it as a prequel (§3.4), and it is
      reversible, because concluding something is a judgement and judgements change.

  A campaign nobody has opened yet is neither: it is `:unstarted`, which the library
  says out loud rather than showing an empty row that looks broken.

  ## Status is derived where it can be

  `:playing` versus `:unstarted` is a fact about the scenes list, not a flag somebody
  has to remember to set — so it is read, never stored. Only `finished_at` is stored,
  because "this story is over" is the one thing the data cannot work out for itself.
  """

  alias Polyphony.Library
  alias Polyphony.ReadModels.ArcEntry
  alias Polyphony.Repo

  @kind "campaign"

  @type status :: :unstarted | :playing | :finished

  @doc "The kind under which campaigns are stored in the library."
  @spec kind() :: String.t()
  def kind, do: @kind

  @doc """
  Every campaign owned by `owner`, newest first (the library's own order).

  **Published snapshots are excluded.** They share the `"campaign"` kind because they
  share a table, and nothing else: a snapshot can't be played, finished, cast or
  reviewed, and its payload is a `Library.Snapshot` with none of a campaign's fields.
  Handing one to anything in this module used to raise — `Snapshot` is a struct, so
  `payload[:scenes]` has no `Access` to go through — which meant publishing anything
  took the library down.
  """
  @spec list(term(), keyword()) :: [map()]
  def list(owner, opts \\ []) do
    owner
    |> Library.list_for_owner(opts)
    |> Enum.filter(&campaign?/1)
  end

  @doc """
  Is this library entry a campaign somebody is working on, rather than a frozen copy
  of one? The one place the distinction is made, so callers stop inferring it from
  `kind`.
  """
  @spec campaign?(map()) :: boolean()
  def campaign?(%{kind: @kind} = entry), do: not Library.snapshot?(entry)
  def campaign?(_entry), do: false

  @doc """
  Where a campaign is in its life.

    * `:unstarted` — made and never opened. No scenes.
    * `:playing` — scenes have happened and it hasn't been concluded.
    * `:finished` — deliberately concluded (§2.5c).

  Derived from the payload rather than stored, apart from the one bit that can't be.
  """
  @spec status(map() | nil) :: status()
  def status(nil), do: :unstarted

  # `Map.get/2` rather than `payload[...]`: the latter needs `Access`, which a struct
  # doesn't implement, so a payload of an unexpected shape raised instead of answering.
  # Defence in depth — `list/2` already keeps snapshots out — but a lifecycle read is
  # exactly the kind of thing that gets called from somewhere new.
  def status(payload) do
    cond do
      Map.get(payload, :finished_at) -> :finished
      (Map.get(payload, :scenes) || []) != [] -> :playing
      true -> :unstarted
    end
  end

  @doc "How a status reads on a library row."
  @spec status_label(status()) :: String.t()
  def status_label(:playing), do: "Playing"
  def status_label(:finished), do: "Finished"
  def status_label(_), do: "Not started"

  @doc """
  Conclude a campaign — a statement, not filing.

  Deliberately does **not** archive: a finished campaign is the one you most want to be
  able to find, to read back or to name as a prequel. Closing any open scene is the
  caller's job through the normal path, because a scene closing is an event and this is
  a library write.
  """
  @spec finish(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def finish(id, opts \\ []), do: stamp_finished(id, now(opts), opts)

  @doc "Un-conclude it. Reversible, because concluding something is a judgement."
  @spec reopen(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def reopen(id, opts \\ []), do: stamp_finished(id, nil, opts)

  defp stamp_finished(id, value, opts) do
    case Library.get(id, opts) do
      nil ->
        {:error, :not_found}

      entry ->
        payload = entry |> Library.payload() |> Map.put(:finished_at, value)
        Library.update_payload(id, payload, opts)
    end
  end

  defp now(opts), do: Keyword.get(opts, :now, NaiveDateTime.utc_now())

  @doc """
  How many arc proposals are waiting on this campaign — its cast's plus its world's.

  What the library row's *3 to review* counts, and the same thing the scene gate will
  block on, so the number an author sees before opening a campaign is the number that
  will stop them.
  """
  @spec pending_review(map(), keyword()) :: non_neg_integer()
  def pending_review(entry, opts \\ [])

  # Nothing is ever waiting on a frozen copy: it has no cast to propose about and no
  # next scene to gate.
  def pending_review(%{frozen: true}, _opts), do: 0

  def pending_review(entry, opts) do
    repo = Keyword.get(opts, :repo, Repo)
    payload = Library.payload(entry) || %{}

    # Counted off one flat list rather than summing per-character lengths: `Enum.sum/1`
    # is spec'd `:: number()` upstream, so a count of proposals reads as possibly-float,
    # while `length/1` is provably a non-negative integer.
    cast_count =
      (Map.get(payload, :character_ids) || [])
      |> Enum.uniq()
      |> Enum.flat_map(&ArcEntry.list_proposed(repo, &1))
      |> length()

    cast_count + length(ArcEntry.list_proposed_world(repo, entry.id))
  end

  @doc """
  The campaign each of `owner`'s characters belongs to, as `%{character_id => entry}`.

  Characters don't cross campaigns (§2.7), so every one belongs to exactly **one** —
  which is what makes the library's grouping free rather than a judgement call, and
  what keeps the list navigable at forty walk-ons. A character in no campaign yet maps
  to nothing and the caller decides where to put them.
  """
  @spec by_character(term(), keyword()) :: %{String.t() => map()}
  def by_character(owner, opts \\ []) do
    for campaign <- list(owner, opts),
        payload = Library.payload(campaign) || %{},
        id <- Map.get(payload, :character_ids) || [],
        into: %{},
        do: {to_string(id), campaign}
  end

  @doc """
  A campaign's name, or the placeholder the library shows for an unnamed one.

  A frozen snapshot has no name of its own and takes its world's, so it's routed to
  the read that knows that rather than rendering as *Untitled campaign* over a story
  that plainly has a title.
  """
  @spec name(map()) :: String.t()
  def name(entry) do
    cond do
      Library.snapshot?(entry) -> Polyphony.Reading.Session.title(Library.payload(entry))
      true -> named(Library.payload(entry))
    end
  end

  defp named(%{name: n}) when is_binary(n) and n != "", do: n
  defp named(_payload), do: "Untitled campaign"
end
