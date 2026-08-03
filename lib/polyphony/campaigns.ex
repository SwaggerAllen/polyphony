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

  @doc "Every campaign owned by `owner`, newest first (the library's own order)."
  @spec list(term(), keyword()) :: [map()]
  def list(owner, opts \\ []) do
    owner
    |> Library.list_for_owner(opts)
    |> Enum.filter(&(&1.kind == @kind))
  end

  @doc """
  Where a campaign is in its life.

    * `:unstarted` — made and never opened. No scenes.
    * `:playing` — scenes have happened and it hasn't been concluded.
    * `:finished` — deliberately concluded (§2.5c).

  Derived from the payload rather than stored, apart from the one bit that can't be.
  """
  @spec status(map() | nil) :: status()
  def status(nil), do: :unstarted

  def status(payload) do
    cond do
      payload[:finished_at] -> :finished
      (payload[:scenes] || []) != [] -> :playing
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
  def pending_review(entry, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    payload = Library.payload(entry) || %{}

    cast_count =
      (payload[:character_ids] || [])
      |> Enum.uniq()
      |> Enum.map(&length(ArcEntry.list_proposed(repo, &1)))
      |> Enum.sum()

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
        id <- payload[:character_ids] || [],
        into: %{},
        do: {to_string(id), campaign}
  end

  @doc "A campaign's name, or the placeholder the library shows for an unnamed one."
  @spec name(map()) :: String.t()
  def name(entry) do
    case Library.payload(entry) do
      %{name: n} when is_binary(n) and n != "" -> n
      _ -> "Untitled campaign"
    end
  end
end
