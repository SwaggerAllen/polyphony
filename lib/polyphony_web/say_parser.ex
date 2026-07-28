defmodule PolyphonyWeb.SayParser do
  @moduledoc """
  Parse a player's composer text into ordered speech **moves**, inferring aloud vs.
  whisper from the text itself rather than an up-front toggle — so one submission can
  say something aloud and whisper something else.

  Convention: everything is spoken **aloud**, except a parenthetical whisper —
  `(whisper to NAME: text)` (also `(whisper NAME: text)`, case-insensitive, and
  comma-separated names for a shared whisper). Each aloud run and each whisper becomes
  its own move, in the order they appear, so:

      Nice to meet you. (whisper to Bram: I don't trust him)

  yields an aloud line and a private line addressed to Bram.
  """
  alias Polyphony.TurnPacket.Move

  # (whisper [to] NAME[, NAME…]: content) — dotall + case-insensitive; content is
  # non-greedy up to the closing paren.
  @whisper ~r/\(\s*whisper(?:\s+to)?\s+([^:)]+?)\s*:\s*(.*?)\)/is

  @spec parse(String.t()) :: [Move.t()]
  def parse(text) when is_binary(text) do
    text
    |> spans([])
    |> Enum.flat_map(&to_move/1)
    |> Enum.with_index(1)
    |> Enum.map(fn {m, i} -> %Move{m | seq: i} end)
  end

  # Walk the text, peeling off each whisper parenthetical and the aloud run before it.
  defp spans(text, acc) do
    case Regex.run(@whisper, text, return: :index) do
      nil ->
        Enum.reverse([{:aloud, text} | acc])

      [{start, len}, {ts, tl}, {cs, cl}] ->
        before = binary_part(text, 0, start)
        targets = binary_part(text, ts, tl)
        content = binary_part(text, cs, cl)
        rest_at = start + len
        rest = binary_part(text, rest_at, byte_size(text) - rest_at)
        spans(rest, [{:whisper, targets, content}, {:aloud, before} | acc])
    end
  end

  defp to_move({:aloud, text}) do
    case String.trim(text) do
      "" -> []
      said -> [%Move{type: :speech, content: said, addressed_to: [], audibility: :normal}]
    end
  end

  defp to_move({:whisper, targets, content}) do
    case String.trim(content) do
      "" ->
        []

      said ->
        to = targets |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
        [%Move{type: :speech, content: said, addressed_to: to, audibility: :private}]
    end
  end
end
