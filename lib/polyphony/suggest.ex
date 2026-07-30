defmodule Polyphony.Suggest do
  @moduledoc """
  Suggestion mode (§11): generate the user's next turn on demand — for when
  they're unsure how to react, or the scene needs a filler beat.

  The one hard rule: **generate from the character's filtered view, not the
  user's omniscient view.** The user knows everything; their character doesn't.
  Because the suggestion is built with `Polyphony.Context.to_messages/2` — which
  filters live events through `Polyphony.Visibility` — a suggestion structurally
  cannot react to a poisoning the character never learned about.

  Produces 2–3 editable variants and accepts an optional steer ("keep it brief",
  "deflect", "just a reaction").

  This is deliberately **separate from director-mode suggestion** (an omniscient
  "what would be dramatically interesting now") — same button shape, different
  context. Do not let the character one leak omniscience.
  """

  alias Polyphony.{Context, Generation}
  alias Polyphony.Context.SceneContext

  @default_count 3

  @doc """
  Produce editable `TurnPacket` variants for the user's character.

  Options: `:context` (the character's `SceneContext`), `:live_events` (raw —
  filtered here), `:members`, `:count` (default 3), `:steer`, `:provider`.
  """
  @spec variants(keyword() | map()) :: {:ok, [Polyphony.TurnPacket.t()]} | {:error, term()}
  def variants(opts) do
    opts = Map.new(opts)
    ctx = fetch_context!(opts)
    count = Map.get(opts, :count, @default_count)

    base =
      Context.to_messages(ctx,
        live_events: Map.get(opts, :live_events, []),
        members: Map.get(opts, :members, [])
      )

    gen_opts = gen_opts(opts)

    results = Enum.map(1..count, fn i -> draft(base, i, Map.get(opts, :steer), gen_opts) end)

    case for({:ok, p} <- results, do: p) do
      [] -> {:error, {:no_variants, first_error(results)}}
      list -> {:ok, list}
    end
  end

  # The reason a draft failed — surfaced so a caller (the Expand button) can show *why*,
  # not a generic "couldn't draft". With `count > 1` this is the first failure; the
  # single-draft Expand path has exactly one.
  defp first_error(results) do
    Enum.find_value(results, :unknown, fn
      {:error, reason} -> reason
      _ -> false
    end)
  end

  defp draft(base, i, steer, gen_opts) do
    messages =
      base ++
        steer_message(steer) ++
        [
          %{
            role: "system",
            content: "Draft option #{i}. Offer a distinct, in-character reaction."
          }
        ]

    Generation.generate(messages, gen_opts)
  end

  defp steer_message(nil), do: []
  defp steer_message(""), do: []
  defp steer_message(steer), do: [%{role: "user", content: "Steer: #{steer}"}]

  defp fetch_context!(%{context: %SceneContext{} = ctx}), do: ctx
  defp fetch_context!(_), do: raise(ArgumentError, "Suggest.variants requires a :context")

  # Forward the provider (if injected) plus cost attribution — a user-initiated
  # suggestion is the user's spend (§B5), metered like authoring.
  defp gen_opts(opts) do
    Enum.flat_map([:provider, :user_id, :campaign_id, :usage_kind], fn key ->
      case Map.get(opts, key) do
        nil -> []
        value -> [{key, value}]
      end
    end)
  end
end
