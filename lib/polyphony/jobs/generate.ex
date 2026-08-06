defmodule Polyphony.Jobs.Generate do
  @moduledoc """
  One authoring generation, run where a closing tab can't reach it.

  The counterpart to `Polyphony.Generations` — see that module for why the result is
  parked rather than written straight onto the entry.

  ## The registry is a `case`, on purpose

  Every operation is named here and matched literally. The obvious alternative is to put
  a module and function in the job args and apply them, and it would be shorter; it
  would also mean an authorization-free remote call whose target is decided by data in a
  row. Job args are ours today, and "today" is doing a lot of work in that sentence.
  The `case` is also the list of everything the editors can ask for, which is worth
  having written down somewhere.

  ## Retries

  `max_attempts: 2`. One retry, because these are single provider calls where a
  transient 502 is common and re-running costs one call rather than a whole campaign's
  worth (which is why `Jobs.QuickBuild` takes none). An operation that fails twice
  records the failure and the screen says so — a generation that quietly never arrives
  is the thing this whole mechanism exists to stop.
  """
  use Oban.Worker, queue: :generation, max_attempts: 2

  require Logger

  alias Polyphony.{Generations, Library, Owner}
  alias Polyphony.Authoring.{Autofill, Cover, StubGen}
  alias Polyphony.Suggest
  alias Polyphony.ReadModels.GenerationRun
  alias Polyphony.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => id}, attempt: attempt, max_attempts: max}) do
    case GenerationRun.get(Repo, id) do
      nil ->
        # Superseded by a later press of the same control, or the subject is gone.
        :ok

      %GenerationRun{status: "done"} ->
        :ok

      run ->
        run(run, attempt, max)
    end
  end

  defp run(run, attempt, max) do
    result = apply_op(run.op, Generations.request_of(run))
    Generations.finish(run.id, result)

    case result do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("[generation] #{run.op} failed: #{inspect(reason)}")

        # Let Oban retry a first failure, but don't report the last one as an error:
        # the run row already carries it and the screen has already been told, so a
        # discarded job on top of that is noise in a queue somebody watches.
        if attempt < max, do: {:error, reason}, else: :ok
    end
  end

  # ── The operations ────────────────────────────────────────────────────────────
  #
  # Each mirrors exactly what the screen used to call inside its `start_async`, so the
  # result shape the screen folds back in is unchanged. Anything that isn't already
  # `{:ok, _} | {:error, _}` is wrapped, because that is the contract a result is
  # delivered under.

  defp apply_op("autofill.all", %{kind: kind, brief: brief, current: current, opts: opts}),
    do: Autofill.generate_all(kind, brief, current, opts)

  defp apply_op("autofill.field", %{kind: kind, field: field, current: current, opts: opts}),
    do: Autofill.generate_field(kind, field, current, opts)

  defp apply_op("autofill.paragraph", %{kind: kind, field: field, opts: opts}),
    do: Autofill.generate_paragraph(kind, field, opts)

  defp apply_op("autofill.facts", %{current: current, opts: opts}),
    do: Autofill.suggest_facts(current, opts)

  defp apply_op("autofill.relationships", %{current: current, opts: opts}),
    do: Autofill.suggest_relationships(current, opts)

  defp apply_op("autofill.boundaries", %{current: current, opts: opts}),
    do: Autofill.suggest_boundaries(current, opts)

  defp apply_op("autofill.premise", %{opts: opts}),
    do: Autofill.generate_campaign_premise(opts)

  defp apply_op("autofill.campaign_opening", %{opts: opts}),
    do: Autofill.generate_campaign_opening(opts)

  defp apply_op("autofill.narration", %{opts: opts}),
    do: Autofill.generate_narration(opts)

  defp apply_op("autofill.scene_opening", %{opts: opts}),
    do: Autofill.generate_scene_opening(opts)

  # The stub's regard back toward the character who introduced them. The screen needs
  # to know which stubs it asked about to patch the answer in, so they ride along.
  defp apply_op("autofill.reciprocals", %{
         source: source,
         pairs: pairs,
         stubs: stubs,
         self_name: self_name,
         self_id: self_id,
         opts: opts
       }) do
    case Autofill.reciprocal_roles(source, pairs, opts) do
      {:ok, roles} -> {:ok, {stubs, self_name, self_id, roles}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_op("cover", %{subject: subject, opts: opts}), do: Cover.generate(subject, opts)

  # ── Play's three ──────────────────────────────────────────────────────────────
  #
  # The reroll is *not* here, and shouldn't be: it supersedes a packet and enqueues
  # `Jobs.GeneratePacket`, so the generation it triggers has always been a job and the
  # replacement arrives on the transcript stream. Wrapping the dispatch would buy
  # nothing.

  defp apply_op("play.mentions", %{prose: prose} = req),
    do: Autofill.extract_mentions(prose, meter(req))

  # Finalising an introduction *writes* — the stub becomes a full sheet — so losing it
  # halfway is the class of failure that leaves a half-written person behind.
  defp apply_op("play.intro", %{entry_id: id} = req) do
    case Library.get(id) do
      nil ->
        {:error, :not_found}

      entry ->
        if StubGen.finalize(entry, Map.get(req, :user_id), meter(req)) == :ok,
          do: {:ok, id},
          else: {:error, :failed}
    end
  end

  # The context is built by the screen and passed in: it comes from ETS (or a local
  # rebuild on a miss), so it costs nothing to carry and keeps the cache-warming logic
  # where the screen already has it.
  defp apply_op("play.compose", %{opts: opts}), do: Suggest.variants(opts)

  # Who this generation is billed to, carried on the request the screen built (§B5).
  # `campaign_id` is optional and absent for a request that isn't about one — the
  # library's bulk stub fill, for instance — so it is taken rather than required.
  # Filling a batch of pending stubs. Best-effort per stub, exactly as the campaign
  # screen did it — one that can't be written leaves the rest alone and is counted.
  defp apply_op("campaign.stubs", %{ids: ids, user_id: user_id}) do
    {ok, bad} =
      Enum.reduce(ids, {0, 0}, fn id, {ok, bad} ->
        case Library.get(id) do
          nil ->
            {ok, bad + 1}

          entry ->
            if StubGen.finalize(entry, user_id) == :ok, do: {ok + 1, bad}, else: {ok, bad + 1}
        end
      end)

    {:ok, {ok, bad}}
  end

  defp apply_op(op, _request), do: {:error, {:unknown_operation, op}}

  # Who a generation is billed to, carried on the request the screen built (§B5).
  # `campaign_id` is optional and absent for a request that isn't about one — the
  # library's bulk stub fill, for instance — so it is taken rather than required.
  defp meter(req) do
    for key <- [:user_id, :campaign_id], value = Map.get(req, key), do: {key, value}
  end

  @doc """
  The owner of a subject, for callers that need to attribute usage — kept here so the
  worker and the screens agree on what a subject is.
  """
  @spec owner_of(term()) :: Owner.t() | nil
  def owner_of(subject) do
    case Library.get(subject) do
      nil -> nil
      entry -> Owner.coerce(entry.owner_id)
    end
  end
end
