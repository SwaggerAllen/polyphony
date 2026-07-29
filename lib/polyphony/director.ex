defmodule Polyphony.Director do
  @moduledoc """
  The Director's per-beat decision (§10).

  In the running system the Director is a Commanded event handler that observes
  `BeatClosed` and enqueues Oban jobs — **never an LLM call inside the handler**
  (rule 1); the job output is dispatched as commands. This module is the pure/
  stubbable core that a job runs:

    1. **Stage 1** — `Arbitration.classify/2`: mechanical, free, deterministic.
    2. **Stage 2** — one judgment call (`decide/1`) that rules on the *forwarded*
       proposals, chooses the cast, authors world events, and sets control flow.
       One call so the decisions are internally consistent (§10).

  The two stages are merged into a `resolved` plan: every accepted proposal, the
  ordered cast, and the world events — including **rejections rendered
  in-fiction** (§10: "she reaches for the door; it's locked" is a world event,
  not an error, and becomes history the character learns from).

  Routed to the cheap tier (routing is classification, not prose, §9). Thinking is a
  per-campaign choice (`Polyphony.LLM.Settings`, default off) since the reasoning trace
  shares the output budget; the decision is forced into JSON mode and self-corrects a
  malformed reply before giving up.
  """

  require Logger

  alias Polyphony.LLM.Provider
  alias Polyphony.Director.{Arbitration, Decision, Proposal}
  alias Polyphony.Events.WorldEventOccurred

  @type resolved :: %{
          cast: [%{character_id: term(), pacing_note: String.t() | nil}],
          control: :continue | :yield_to_user,
          accepted: [Proposal.t()],
          world_events: [WorldEventOccurred.t()],
          scene_actions: [map()],
          introductions: [%{name: String.t(), reason: String.t() | nil}],
          search_need: String.t() | nil
        }

  @doc """
  Run both arbitration stages for a beat and return the resolved plan.

  Options: `:proposals`, `:options` (topology for Stage 1), `:messages` (the
  Director's judgment context — omniscient, §9), `:scene_id`, `:beat`,
  `:provider` (defaults to the configured one; inject a stub in tests), plus any
  provider opts.
  """
  @spec decide(keyword() | map()) :: {:ok, resolved()} | {:error, term()}
  def decide(opts) do
    opts = Map.new(opts)
    proposals = Map.get(opts, :proposals, [])
    options = Map.get(opts, :options, %{exits: [], entities: []})
    scene_id = Map.get(opts, :scene_id)
    beat = Map.get(opts, :beat)

    arb = Arbitration.classify(proposals, options)

    with {:ok, decision} <- judgment(opts, arb) do
      {:ok, resolve(decision, arb, scene_id, beat)}
    end
  end

  # ── Stage 2: the judgment call ──────────────────────────────────────────────

  # How many times to feed a malformed decision back and ask the model to correct it,
  # mirroring the character path (`Generation`). A decode/schema error means the model
  # produced *something* wrong — recoverable by self-correction — which is a different
  # failure from an empty response (nothing to correct; retried on the heavy model in
  # `RunBeat`). The two are handled distinctly, never conflated.
  @max_decode_retries 2

  defp judgment(opts, arb) do
    provider = Map.get(opts, :provider) || Provider.default()
    base = Map.get(opts, :messages, [])
    messages = base ++ [%{role: "user", content: forwarded_prompt(arb.forwarded)}]

    # Forward provider-relevant opts (model, hints, cast/control hints for the
    # Mock) while dropping the Director's own inputs. `response: :decision` tells
    # a structure-aware provider which shape to emit; thinking is a caller choice.
    call_opts =
      opts
      |> Map.drop([:proposals, :options, :messages, :provider])
      |> Map.put(:response, :decision)
      |> Map.put_new(:thinking, false)
      |> Enum.into([])

    metered =
      Keyword.put(call_opts, :provider, provider) ++
        for(k <- [:user_id, :campaign_id, :usage_kind], v = Map.get(opts, k), do: {k, v})

    judge(messages, metered, @max_decode_retries)
  end

  # The call → decode → validate loop. A provider error (empty/refusal/transport) is
  # terminal here; a *decode* or *schema* error self-corrects until the retries run out.
  defp judge(messages, metered, retries_left) do
    case Polyphony.LLM.call(messages, metered) do
      {:ok, text} ->
        case parse_decision(text) do
          {:ok, decision} ->
            {:ok, decision}

          {:retry, _kind} when retries_left > 0 ->
            judge(correct(messages, text), metered, retries_left - 1)

          {:retry, :schema} ->
            {:error, :invalid_decision}

          {:retry, :json} ->
            {:error, {:director, :invalid_json}}
        end

      {:error, reason} ->
        {:error, {:director, reason}}
    end
  end

  # A malformed decision is `{:retry, kind}` — decode failure (`:json`) vs schema
  # mismatch (`:schema`) kept distinct, so neither is mistaken for the other or for an
  # empty response.
  defp parse_decision(text) do
    case Jason.decode(text) do
      {:ok, data} ->
        case Decision.parse(data) do
          {:ok, decision} -> {:ok, decision}
          {:error, %Ecto.Changeset{}} -> {:retry, :schema}
        end

      {:error, %Jason.DecodeError{}} ->
        {:retry, :json}
    end
  end

  # Feed the bad output back verbatim and ask for a clean correction (§12).
  defp correct(messages, previous) do
    messages ++
      [
        %{role: "assistant", content: previous},
        %{
          role: "user",
          content:
            "That was not a valid JSON decision object. Respond with ONLY the JSON object " <>
              "described above — no prose, no markdown, no code fences."
        }
      ]
  end

  # The decision JSON contract. Kept explicit in the final message (and paired with the
  # provider's JSON mode) because the model otherwise free-forms markdown prose — the
  # `**Cast:** …` responses that fail `Jason.decode`.
  @decision_format """
  Respond with ONLY a single JSON object — no prose, no markdown, no code fences, no \
  reasoning — of exactly this shape:
  {"control": "continue" | "yield_to_user",
   "cast": [{"character_id": "<one of the exact ids listed above>", "pacing_note": "<optional short note>"}],
   "world_events": [{"content": "<something that happens in the world, or omit>"}],
   "introductions": [{"name": "<name>", "reason": "<why, or omit>"}],
   "proposal_rulings": [{"actor_id": "<id>", "accept": true, "reason": "<why>"}]}
  Empty arrays are fine. `cast` must use the exact character ids from the roster above.\
  """

  defp forwarded_prompt([]),
    do:
      "No proposals need arbitration. Decide the cast, any world events, and control flow.\n\n" <>
        @decision_format

  defp forwarded_prompt(proposals) do
    lines = Enum.map_join(proposals, "\n", fn p -> "- #{p.actor_id}: #{p.detail || p.target}" end)

    "Rule on these proposals, then decide cast, world events, and control flow:\n" <>
      lines <> "\n\n" <> @decision_format
  end

  # ── Merge the two stages into one plan ──────────────────────────────────────

  defp resolve(%Decision{} = decision, arb, scene_id, beat) do
    judged = Map.new(decision.proposal_rulings || [], &{&1.actor_id, &1})

    {judged_accepted, judged_rejected} =
      Enum.split_with(arb.forwarded, fn p ->
        case Map.get(judged, to_string(p.actor_id)) do
          %{accept: true} -> true
          _ -> false
        end
      end)

    rejection_world_events =
      rejection_events(arb.rejected, scene_id, beat) ++
        judged_rejection_events(judged_rejected, judged, scene_id, beat)

    authored =
      Enum.map(decision.world_events || [], fn w ->
        %WorldEventOccurred{scene_id: w.scene_id || scene_id, beat: beat, content: w.content}
      end)

    %{
      cast:
        Enum.map(
          decision.cast || [],
          &%{character_id: &1.character_id, pacing_note: &1.pacing_note}
        ),
      control: decision.control,
      accepted: arb.accepted ++ judged_accepted,
      world_events: authored ++ rejection_world_events,
      scene_actions: decision.scene_actions || [],
      introductions: Enum.map(decision.introductions || [], &%{name: &1.name, reason: &1.reason}),
      search_need: decision.search_need
    }
  end

  # ── Rejections → in-fiction world events (§10) ──────────────────────────────

  @doc "Render mechanically-rejected proposals as in-fiction world events."
  @spec rejection_events([{Proposal.t(), atom()}], term(), term()) :: [WorldEventOccurred.t()]
  def rejection_events(rejected, scene_id, beat) do
    Enum.map(rejected, fn {proposal, reason} ->
      %WorldEventOccurred{
        scene_id: scene_id,
        beat: beat,
        content: rejection_text(proposal, reason)
      }
    end)
  end

  defp judged_rejection_events(rejected_proposals, judged, scene_id, beat) do
    Enum.map(rejected_proposals, fn p ->
      reason = get_in(judged, [to_string(p.actor_id), Access.key(:reason)]) || "it doesn't work"
      %WorldEventOccurred{scene_id: scene_id, beat: beat, content: rejection_text(p, reason)}
    end)
  end

  defp rejection_text(%Proposal{actor_id: who, target: target}, :no_such_exit),
    do: "#{who} moves to leave toward #{target}, but there is no way through."

  defp rejection_text(%Proposal{actor_id: who, target: target}, :no_such_entity),
    do: "#{who} reaches for #{target}, but it isn't here."

  defp rejection_text(%Proposal{actor_id: who, detail: detail}, reason) when is_binary(reason),
    do: "#{who} tries to #{detail || "act"}, but #{reason}."

  defp rejection_text(%Proposal{actor_id: who}, reason),
    do: "#{who}'s attempt fails (#{inspect(reason)})."
end
