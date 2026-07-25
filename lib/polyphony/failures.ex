defmodule Polyphony.Failures do
  @moduledoc """
  User-facing failures with retry (§12).

  Every *terminal* generation failure — a refusal that survived the model swap, a
  job that exhausted its retries — is recorded here and broadcast to the user as a
  `generation.failed` message carrying a `failure_id` and its affordances:

    * **retry** — re-enqueue the exact work (`retry/1`).
    * **edit + resubmit** — for a **refusal** (`editable: true`), the user rephrases
      the prompt/context and resubmits (`retry_edited/2`). DeepInfra adds no filter
      layer, so a refusal is the model's trained behavior; editing the input is the
      user's lever, alongside the automatic model-swap that already ran.

  A failure is a read-model record (not a narrative event); it is user/system
  only and never reaches a character.
  """

  require Logger

  alias Polyphony.Repo
  alias Polyphony.ReadModels.Failure
  alias Polyphony.Broadcast

  @pubsub Polyphony.PubSub

  @doc """
  Record a terminal failure and broadcast it. `attrs`:

    * `:worker` (module), `:args` (map to re-enqueue with)
    * `:scene_id`, `:beat`, `:subject`, `:operation`, `:kind`, `:reason`
    * `:editable` (default: `kind == :refusal`), `:retryable` (default true)
  """
  def record(attrs, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    kind = normalize(attrs[:kind])

    row =
      Failure.put(repo, %{
        scene_id: attrs[:scene_id] && to_string(attrs[:scene_id]),
        beat: attrs[:beat],
        subject: attrs[:subject] && to_string(attrs[:subject]),
        operation: normalize(attrs[:operation]),
        kind: kind,
        reason: attrs[:reason] && to_string(attrs[:reason]),
        editable: Map.get(Map.new(attrs), :editable, kind == "refusal"),
        retryable: Map.get(Map.new(attrs), :retryable, true),
        worker: worker_str(attrs[:worker]),
        args: stringify(attrs[:args] || %{})
      })

    broadcast(row)
    row
  end

  @doc "Re-enqueue the failed work as-is and mark the failure resolved."
  def retry(id, opts \\ []), do: do_retry(id, %{}, opts)

  @doc """
  Re-enqueue with edits merged into the stored args, then resolve — the refusal
  edit-and-resubmit path. `edits` are string-keyed (e.g. `%{\"messages\" => [...]}`).
  """
  def retry_edited(id, edits, opts \\ []), do: do_retry(id, stringify(edits), opts)

  defp do_retry(id, edits, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    case Failure.get(repo, id) do
      nil ->
        {:error, :not_found}

      %Failure{status: "resolved"} ->
        {:error, :already_resolved}

      row ->
        with {:ok, worker} <- resolve_worker(row.worker) do
          row.args
          |> Map.merge(edits)
          |> worker.new()
          |> Oban.insert!()

          {:ok, resolved} = Failure.resolve(repo, id)
          {:ok, resolved}
        end
    end
  end

  @doc "Open failures for a scene."
  def list_open(scene_id, opts \\ []) do
    Failure.list_open(Keyword.get(opts, :repo, Repo), scene_id)
  end

  # ── Broadcast ────────────────────────────────────────────────────────────────

  defp broadcast(%Failure{} = row) do
    if row.scene_id do
      Phoenix.PubSub.broadcast(@pubsub, Broadcast.topic(row.scene_id, :omniscient), {
        :polyphony_event,
        %{
          type: "generation.failed",
          viewer: "omniscient",
          failure_id: row.id,
          scene_id: row.scene_id,
          beat: row.beat,
          subject: row.subject,
          operation: row.operation,
          kind: row.kind,
          reason: row.reason,
          editable: row.editable,
          retryable: row.retryable
        }
      })
    end

    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp resolve_worker(str) do
    {:ok, String.to_existing_atom(str)}
  rescue
    ArgumentError -> {:error, :unknown_worker}
  end

  defp normalize(nil), do: nil
  defp normalize(v) when is_atom(v), do: v |> to_string() |> String.trim_leading("Elixir.")
  defp normalize(v) when is_binary(v), do: v

  # The worker keeps its fully-qualified form so it resolves back to a module.
  defp worker_str(nil), do: nil
  defp worker_str(mod) when is_atom(mod), do: to_string(mod)
  defp worker_str(str) when is_binary(str), do: str

  # Oban args must be JSON-serializable with string keys.
  defp stringify(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
