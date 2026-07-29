defmodule Polyphony.LLM.Settings do
  @moduledoc """
  Per-campaign LLM tuning (§9), resolved from a scene's campaign.

  Lets an author tune the generation calls — whether the Director reasons (thinking),
  and the Director/character output-token budgets — from the campaign screen at
  **runtime**, instead of baking them into env vars and redeploying. Stored on the
  campaign's `Library` payload under `:llm`; falls back to sensible defaults when a
  key (or the whole campaign) is absent, so a scene with no campaign still works.

  Resolved fresh per beat, so an edit takes effect on the next beat — no restart.
  """
  require Logger

  alias Polyphony.{App, Library}
  alias Polyphony.Events.SceneOpened

  @type t :: %{
          director_thinking: boolean(),
          director_max_tokens: pos_integer(),
          character_max_tokens: pos_integer()
        }

  # Director thinking defaults OFF: with thinking on, the reasoning trace shares the
  # output budget and starves the decision JSON (empty/truncated). Off keeps the whole
  # budget for the JSON.
  @defaults %{director_thinking: false, director_max_tokens: 2048, character_max_tokens: 1024}

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
