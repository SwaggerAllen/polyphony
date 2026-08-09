defmodule Polyphony.Authoring.SceneGate do
  @moduledoc """
  The arc-review gate on **opening a new scene** (§3.0).

  Every unreviewed arc proposal is a gap between who a character is on paper and who
  they've become in the story — and generation works from the paper. Let it run and
  the Director writes someone who stopped existing two scenes ago. So opening a new
  scene requires that **every character being cast has no pending arc proposals**, and
  that the **campaign has no pending world arc** (world arc feeds every generation in
  the campaign).

  Scoping is what makes it tolerable (§3.0):

    * **Per-cast, not per-backlog.** Nineteen pending across three scenes doesn't block a
      scene with two clean characters — only the *selected cast* is evaluated. (World arc
      is campaign-wide by nature, so it always counts.)
    * **Accept-all is the intended fast path**, not a loophole — the review screen offers
      it, so one tap produces sheets that match the story.
    * **Never blocks the open scene**, only opening a *new* one; the current scene closes
      normally regardless.

  Keyed by character **id** — the identity scenes and arc extraction both use
  (`CharacterEntered.character_id`, now the library id since §5.2's mint flip). The
  gate used to resolve library ids to names to do this lookup; it doesn't any more,
  because there is only one identity again.

  ## The gate is met on the row (STR-62)

  `row_states/3` is the per-character read the Set-the-scene cast rows render: how
  many proposals are pending, whether extraction is still running (an `ExtractArc`
  job not yet done — a wait, not a fault), and whether it failed (an open arc
  failure, which carries the retry). Failure is per-character — one person's
  extraction can fail while everybody else's succeeded — which is why this is a map
  per id rather than a verdict for the form.

  `check/3` stays the correctness core: whatever the rows say, a scene must not open
  past pending arc, and the rows are how an author clears it without leaving.
  """

  import Ecto.Query

  alias Polyphony.Repo
  alias Polyphony.ReadModels.ArcEntry
  alias Polyphony.ReadModels.Failure

  @type blocked :: %{characters: [String.t()], world: non_neg_integer()}

  @type row_state :: %{
          pending: non_neg_integer(),
          running: boolean(),
          failure: Failure.t() | nil
        }

  @doc """
  May a new scene open for `campaign_id` with cast `character_ids`? `:ok`, or
  `{:blocked, %{characters: [id], world: count}}` listing the cast members with
  pending arc and the count of pending world-arc proposals. The caller renders those
  ids as names — the gate deals only in identity.
  """
  @spec check(term(), [term()], module()) :: :ok | {:blocked, blocked()}
  def check(campaign_id, character_ids, repo \\ Repo) do
    blocked_chars =
      character_ids
      |> Enum.map(&to_string/1)
      |> Enum.uniq()
      |> Enum.filter(fn id -> ArcEntry.list_proposed(repo, id) != [] end)

    world_pending = length(ArcEntry.list_proposed_world(repo, campaign_id))

    if blocked_chars == [] and world_pending == 0 do
      :ok
    else
      {:blocked, %{characters: blocked_chars, world: world_pending}}
    end
  end

  @doc """
  The per-row arc state for a cast (STR-62): `%{characters: %{id => row_state},
  world: pending_world_count}`. Every id in `character_ids` gets an entry — a row
  with nothing to say still says *up to date*.
  """
  @spec row_states(term(), [term()], module()) :: %{
          characters: %{String.t() => row_state()},
          world: non_neg_integer()
        }
  def row_states(campaign_id, character_ids, repo \\ Repo) do
    ids = character_ids |> Enum.map(&to_string/1) |> Enum.uniq()

    pending = ArcEntry.proposed_counts(repo, ids)
    failures = open_arc_failures(repo, ids)
    running = running_extractions(repo, ids)

    characters =
      Map.new(ids, fn id ->
        {id,
         %{
           pending: Map.get(pending, id, 0),
           running: MapSet.member?(running, id),
           failure: Map.get(failures, id)
         }}
      end)

    %{characters: characters, world: length(ArcEntry.list_proposed_world(repo, campaign_id))}
  end

  # Newest open arc-extraction failure per character. Arc failures are author-facing
  # (`Polyphony.Failures` keeps them omniscient-only on broadcast), and this read is
  # for the author's own casting form.
  defp open_arc_failures(repo, ids) do
    repo.all(
      from(f in Failure,
        where: f.subject in ^ids and f.operation == "arc" and f.status == "open",
        order_by: [asc: f.inserted_at]
      )
    )
    |> Map.new(&{&1.subject, &1})
  end

  # An extraction that hasn't finished: an `ExtractArc` job for this character that
  # Oban still holds. `retryable` counts — a job between attempts is still a wait,
  # not a fault; the fault only exists once the failure row is written.
  defp running_extractions(repo, ids) do
    repo.all(
      from(j in Oban.Job,
        where:
          j.worker == "Polyphony.Jobs.ExtractArc" and
            j.state in ["available", "scheduled", "executing", "retryable"] and
            fragment("?->>'character_id' = ANY(?)", j.args, ^ids),
        select: fragment("?->>'character_id'", j.args)
      )
    )
    |> MapSet.new()
  end
end
