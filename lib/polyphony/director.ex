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

  Routed to the cheap tier (routing is classification, not prose, §9) with
  thinking enabled for the routing decision (§3).
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

  defp judgment(opts, arb) do
    provider = Map.get(opts, :provider) || Provider.default()
    base = Map.get(opts, :messages, [])
    messages = base ++ [%{role: "user", content: forwarded_prompt(arb.forwarded)}]

    # Forward provider-relevant opts (model, hints, cast/control hints for the
    # Mock) while dropping the Director's own inputs. `response: :decision` tells
    # a structure-aware provider which shape to emit; thinking is on for routing
    # (§3).
    call_opts =
      opts
      |> Map.drop([:proposals, :options, :messages, :provider])
      |> Map.put(:response, :decision)
      |> Map.put_new(:thinking, true)
      |> Enum.into([])

    with {:ok, text} <- provider.complete(messages, call_opts),
         {:ok, data} <- Jason.decode(text),
         {:ok, decision} <- Decision.parse(data) do
      {:ok, decision}
    else
      {:error, %Ecto.Changeset{}} -> {:error, :invalid_decision}
      {:error, reason} -> {:error, {:director, reason}}
    end
  end

  defp forwarded_prompt([]),
    do: "No proposals need arbitration. Decide the cast, any world events, and control flow."

  defp forwarded_prompt(proposals) do
    lines = Enum.map_join(proposals, "\n", fn p -> "- #{p.actor_id}: #{p.detail || p.target}" end)
    "Rule on these proposals, then decide cast, world events, and control flow:\n" <> lines
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
