defmodule Polyphony.LLM.Settings do
  @moduledoc """
  Per-campaign LLM tuning (§9), resolved from a scene's campaign.

  Lets an author tune the generation calls — whether the Director reasons (thinking),
  the Director/character output-token budgets, and **which model** the campaign runs
  on — from the campaign screen at **runtime**, instead of baking them into env vars
  and redeploying. Stored on the campaign's `Library` payload under `:llm`; falls back
  to sensible defaults when a key (or the whole campaign) is absent, so a scene with no
  campaign still works.

  The two model keys let a campaign point at a better-provisioned DeepInfra model when
  the global default's serverless pool is overloaded (the `engine_overloaded` 429):

    * `model` — the workhorse both the Director and the cast run on. `nil` ⇒ the global
      `DEEPINFRA_MODEL` (`config :polyphony, :llm, deepinfra: [model: …]`).
    * `heavy_model` — the fallback tier (Director empty/refusal/invalid, character
      refusal). `nil` ⇒ the global `[:models, :heavy]`.

  Both nil-default, so an unset campaign behaves exactly as before — the model is
  resolved by the provider/job from app env, not overridden here.

  `service_tier` picks how DeepInfra schedules the request — `"priority"` jumps ahead
  of standard traffic (the escape hatch for `engine_overloaded` under peak load, at a
  price premium), `"flex"` is cheaper but slower/best-effort, `"standard"` (or nil) is
  the default. Applies to every generation the campaign makes.

  Resolved fresh per beat, so an edit takes effect on the next beat — no restart.
  """
  require Logger

  alias Polyphony.{App, Library}
  alias PolyphonyCore.Events.SceneOpened

  @type t :: %{
          director_thinking: boolean(),
          director_max_tokens: pos_integer(),
          character_max_tokens: pos_integer(),
          model: String.t() | nil,
          heavy_model: String.t() | nil,
          service_tier: String.t() | nil
        }

  # Director thinking defaults OFF: with thinking on, the reasoning trace shares the
  # output budget and starves the decision JSON (empty/truncated). Off keeps the whole
  # budget for the JSON. The model keys default nil — "not set, use the global config".
  @defaults %{
    director_thinking: false,
    director_max_tokens: 2048,
    character_max_tokens: 1024,
    model: nil,
    heavy_model: nil,
    service_tier: nil
  }

  # The DeepInfra scheduling tiers; anything else coerces back to nil (⇒ standard).
  @service_tiers ~w(standard priority flex)

  @doc "The default settings (no campaign / unset)."
  @spec defaults() :: t()
  def defaults, do: @defaults

  @doc "Resolve a scene's campaign LLM settings, merged over the defaults."
  @spec for_scene(term()) :: t()
  def for_scene(scene_id) do
    with cid when not is_nil(cid) <- campaign_id(scene_id),
         %{} = payload <- campaign_payload(cid) do
      from_payload(payload)
    else
      _ -> @defaults
    end
  rescue
    e ->
      Logger.warning(
        "[llm-settings] resolve failed for #{inspect(scene_id)}: #{Exception.message(e)}"
      )

      @defaults
  end

  @doc "Extract settings from a campaign payload's `:llm` map, merged over the defaults."
  @spec from_payload(map()) :: t()
  def from_payload(payload) when is_map(payload) do
    raw = Map.get(payload, :llm) || Map.get(payload, "llm") || %{}
    Map.merge(@defaults, coerced(raw))
  end

  def from_payload(_), do: @defaults

  # ── Internals ─────────────────────────────────────────────────────────────────

  defp coerced(raw) do
    Enum.reduce(@defaults, %{}, fn {key, _default}, acc ->
      case fetch(raw, key) do
        {:ok, value} -> Map.put(acc, key, coerce(key, value))
        :error -> acc
      end
    end)
  end

  defp fetch(map, key) do
    cond do
      Map.has_key?(map, key) -> {:ok, Map.get(map, key)}
      Map.has_key?(map, to_string(key)) -> {:ok, Map.get(map, to_string(key))}
      true -> :error
    end
  end

  defp coerce(:director_thinking, value), do: truthy(value)

  defp coerce(key, value) when key in [:director_max_tokens, :character_max_tokens],
    do: to_pos_int(value) || @defaults[key]

  # A model id is a free-form string; blank (an unset form field) means "use the global
  # default", so it coerces back to nil rather than an empty override.
  defp coerce(key, value) when key in [:model, :heavy_model], do: to_model(value)

  # A service tier must be one of the known DeepInfra values; anything else ⇒ nil (the
  # default `standard` scheduling), so a stale/garbage value can't ride into the body.
  defp coerce(:service_tier, value) do
    case to_model(value) do
      tier when tier in @service_tiers -> tier
      _ -> nil
    end
  end

  defp truthy(v) when v in [true, "true", "on", "1", 1], do: true
  defp truthy(_), do: false

  defp to_pos_int(v) when is_integer(v) and v > 0, do: v

  defp to_pos_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} when n > 0 -> n
      _ -> nil
    end
  end

  defp to_pos_int(_), do: nil

  defp to_model(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp to_model(_), do: nil

  defp campaign_id(scene_id) do
    case Commanded.EventStore.stream_forward(App, scene_id, 0, 8) do
      {:error, _} ->
        nil

      stream ->
        Enum.find_value(stream, fn e -> match?(%SceneOpened{}, e.data) && e.data.campaign_id end)
    end
  rescue
    _ -> nil
  end

  defp campaign_payload(campaign_id) do
    case Library.get(campaign_id) do
      nil -> nil
      entry -> Library.payload(entry)
    end
  rescue
    _ -> nil
  end
end
