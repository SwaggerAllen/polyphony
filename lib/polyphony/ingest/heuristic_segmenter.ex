defmodule Polyphony.Ingest.HeuristicSegmenter do
  @moduledoc """
  A deterministic, network-free segmenter (§11) using the common RP prose
  conventions:

    * `"quoted text"` → speech
    * `*asterisked text*` → action
    * `[OOC: ...]` → out-of-character (routed to the Director, not committed)
    * everything else → narration, classified as action

  Every segment's `content` is the inner span verbatim, so the result passes
  `Polyphony.Ingest.verify_verbatim/2` by construction. It does not resolve
  pronouns to `addressed_to` — that's the LLM segmenter's job; here it stays
  empty and the confirmation step lets the user set it.
  """
  @behaviour Polyphony.Ingest.Segmenter

  alias Polyphony.Ingest.Segment

  @token ~r/\[OOC:[^\]]*\]|"[^"]*"|\*[^*]*\*|[^"*\[]+/u

  @impl true
  def segment(prose, _roster \\ []) when is_binary(prose) do
    segments =
      @token
      |> Regex.scan(prose)
      |> Enum.map(fn [tok] -> classify(tok) end)
      |> Enum.reject(&is_nil/1)

    {:ok, segments}
  end

  defp classify("[OOC:" <> rest) do
    content = rest |> String.trim_trailing("]") |> String.trim()
    seg_or_nil(:ooc, content)
  end

  defp classify(<<?", _::binary>> = tok) do
    seg_or_nil(:speech, tok |> String.trim("\"") |> String.trim())
  end

  defp classify(<<?*, _::binary>> = tok) do
    seg_or_nil(:action, tok |> String.trim("*") |> String.trim())
  end

  defp classify(plain) do
    seg_or_nil(:action, String.trim(plain))
  end

  defp seg_or_nil(_type, ""), do: nil
  defp seg_or_nil(type, content), do: %Segment{type: type, content: content}
end
