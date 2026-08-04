defmodule Polyphony.Generations do
  @moduledoc """
  Authoring generations that outlive the tab that asked for them.

  ## Why

  Every ✦ control in the editors ran its provider call in `start_async`. That task is
  linked to the socket, so the work died with it — and these calls take seconds, which
  is precisely the window in which somebody checks a message. The author came back to
  an unfilled field, an untouched-looking button, and a bill for the call.

  ## The shape, and why it isn't "write it to the entry"

  A job produces the **raw result** and parks it here; the screen applies it with the
  same code it always did. The tempting alternative — have the job write the generated
  value straight onto the library entry — would mean re-implementing how each result
  merges, and those rules are the interesting part: ✦ Suggest *appends* to a list
  because a list is authored, Generate-all fills only what's empty, and a cover that
  came back `{:error, :leaked}` is refused rather than saved. A second copy of that
  logic in a worker is a second copy that will drift, and it would drift in the
  direction of overwriting an author's work.

  So the result waits, and the screen stays the only thing that decides what a result
  *means*:

    * **Still watching** — the broadcast arrives, the screen applies it, autosave writes
      it. Exactly what used to happen, one process further away.
    * **Came back later** — `take/1` on mount hands over everything that finished while
      nobody was listening, in the order it finished, and the screen applies each one as
      if it had just arrived.
    * **Still running** — `running/1` restores the spinners, so a reconnect mid-generation
      looks like what it is rather than like a button that did nothing.

  Read exactly once: taking a result deletes it, so a result can't be applied twice by
  two tabs and can't accumulate.

  ## One in flight per control

  The unique `(subject, key)` claim is the same statement the spinner makes. Pressing ✦
  again replaces the claim — you want the second answer — and the first job's result
  lands on a row that no longer exists, so `finish/2` drops it.
  """

  require Logger

  alias Polyphony.ReadModels.GenerationRun
  alias Polyphony.Repo

  @type t :: GenerationRun.t()
  @type result :: {:ok, term()} | {:error, term()}

  @doc "The PubSub topic carrying one subject's generation results."
  @spec topic(term()) :: String.t()
  def topic(subject), do: "generations:#{subject}"

  @doc "Subscribe the caller to a subject's generation results."
  @spec subscribe(term()) :: :ok | {:error, term()}
  def subscribe(subject) do
    Phoenix.PubSub.subscribe(Polyphony.PubSub, topic(subject))
  rescue
    _ -> :ok
  end

  @doc """
  Ask for a generation. `op` names an operation `Polyphony.Jobs.Generate` knows how to
  run; `request` is whatever that operation needs, kept as an Erlang term because it is
  never queried — only handed straight back to the worker.
  """
  @spec request(term(), String.t(), String.t(), term(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def request(subject, key, op, request, opts \\ []) do
    repo = repo(opts)

    row =
      GenerationRun.claim(repo, %{
        subject: to_string(subject),
        key: to_string(key),
        op: to_string(op),
        request: encode(request)
      })

    case Oban.insert(Polyphony.Jobs.Generate.new(%{"id" => row.id})) do
      {:ok, _job} ->
        {:ok, row}

      {:error, reason} ->
        # Nothing is going to run against this claim, so don't leave a spinner on
        # forever — turn it into the failure it already is.
        finish(row.id, {:error, reason}, opts)
        {:error, reason}
    end
  end

  @doc """
  Record a result and tell whoever is listening.

  A run whose row has gone was superseded by a later press of the same control (or the
  subject was deleted). Its answer is dropped rather than delivered: applying it would
  overwrite the newer one the author actually waited for.
  """
  @spec finish(term(), result(), keyword()) :: :ok
  def finish(id, result, opts \\ []) do
    status = if match?({:ok, _}, result), do: "done", else: "failed"

    case GenerationRun.update(repo(opts), id, %{status: status, result: encode(result)}) do
      nil ->
        Logger.debug("[generation] result for a run that is gone (id=#{inspect(id)})")
        :ok

      row ->
        announce(row.subject, {:generation, row.key, result})
        :ok
    end
  end

  @doc """
  The finished results for a subject, oldest first, removed as they're handed over.

  Called on mount: these are the answers that arrived while nobody was watching.
  """
  @spec take(term(), keyword()) :: [{String.t(), result()}]
  def take(subject, opts \\ []) do
    repo(opts)
    |> GenerationRun.take_finished(subject)
    |> Enum.map(&{&1.key, decode(&1.result)})
  end

  @doc "The controls still generating for this subject — the spinners to restore."
  @spec running(term(), keyword()) :: [String.t()]
  def running(subject, opts \\ []) do
    repo(opts)
    |> GenerationRun.list(subject)
    |> Enum.filter(&(&1.status == "running"))
    |> Enum.map(& &1.key)
  end

  @doc "Forget a run — the control was cancelled, or its subject is going away."
  @spec forget(term(), String.t(), keyword()) :: :ok
  def forget(subject, key, opts \\ []), do: GenerationRun.delete(repo(opts), subject, key)

  @doc "The stored request for a run, decoded."
  @spec request_of(t()) :: term()
  def request_of(%GenerationRun{request: bin}), do: decode(bin)

  defp announce(subject, message) do
    Phoenix.PubSub.broadcast(Polyphony.PubSub, topic(subject), message)
    :ok
  rescue
    _ -> :ok
  end

  defp encode(term), do: :erlang.term_to_binary(term)

  defp decode(nil), do: nil

  # `:safe` refuses to fabricate atoms or modules; everything stored here is built from
  # already-loaded structs and literal atoms this app compiled.
  #
  # Registered because the attribute is read by Sobelow, not the compiler, which would
  # otherwise warn it is set and never used (and CI compiles as errors).
  Module.register_attribute(__MODULE__, :sobelow_skip, accumulate: true)
  @sobelow_skip ["Misc.BinToTerm"]
  defp decode(bin) when is_binary(bin), do: :erlang.binary_to_term(bin, [:safe])

  defp repo(opts), do: Keyword.get(opts, :repo, Repo)
end
