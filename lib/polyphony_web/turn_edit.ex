defmodule PolyphonyWeb.TurnEdit do
  @moduledoc """
  Serialize a committed turn to editable text and parse it back — the whole turn,
  not just its spoken lines. A turn surfaces to a viewer as ordered moves
  (thought / speech / action) plus the one self-state field that becomes an event,
  the character's demeanor (`DemeanorReported`). Editing rewrites all of them.

  The text format is one move per line, legible and order-preserving:

      thinks: Careful now.
      Good evening.
      does: steps closer to the fire
      (whisper to Bram: I don't trust him)
      seems: gracious

  A line prefixed `thinks:` is an interior thought, `does:` an action, `seems:` the
  demeanor (folded into the self-state, not a move). Every other line is speech, run
  through `SayParser` so aloud/whisper is inferred from the text exactly as in the
  composer. Move ordering follows line order (`seq` renumbered on parse).
  """
  alias Polyphony.TurnPacket.{Move, SelfState}
  alias PolyphonyWeb.SayParser

  @doc """
  Render a turn's transcript messages (as carried in the play view) to editable text.
  """
  @spec serialize([map()]) :: String.t()
  def serialize(msgs) do
    msgs
    |> Enum.flat_map(&line_for/1)
    |> Enum.join("\n")
  end

  defp line_for(%{kind: "ThoughtOccurred", payload: p}), do: text_line("thinks: ", p[:content])
  defp line_for(%{kind: "ActionTaken", payload: p}), do: text_line("does: ", p[:content])
  defp line_for(%{kind: "DemeanorReported", payload: p}), do: text_line("seems: ", p[:demeanor])

  defp line_for(%{kind: "SpeechUttered", payload: p}) do
    case String.trim(to_string(p[:content] || "")) do
      "" ->
        []

      said ->
        if to_string(p[:audibility]) == "private" do
          to = (p[:addressed_to] || []) |> Enum.join(", ")
          ["(whisper to #{to}: #{said})"]
        else
          [said]
        end
    end
  end

  defp line_for(_), do: []

  defp text_line(prefix, content) do
    case String.trim(to_string(content || "")) do
      "" -> []
      body -> [prefix <> body]
    end
  end

  @doc """
  Parse edited turn text into `{moves, self_state}`. Moves are ordered by line;
  `seq` is renumbered. `seems:` lines set the self-state demeanor. Returns `{[], _}`
  when the turn has no moves (an author clearing it), which the caller rejects.
  """
  @spec parse(String.t()) :: {[Move.t()], SelfState.t()}
  def parse(text) when is_binary(text) do
    {moves, demeanor} =
      text
      |> String.split(~r/\r?\n/)
      |> Enum.reduce({[], nil}, fn line, {moves, demeanor} ->
        case classify(line) do
          {:thought, ""} -> {moves, demeanor}
          {:thought, body} -> {moves ++ [%Move{type: :thought, content: body}], demeanor}
          {:action, ""} -> {moves, demeanor}
          {:action, body} -> {moves ++ [%Move{type: :action, content: body}], demeanor}
          {:demeanor, ""} -> {moves, demeanor}
          {:demeanor, body} -> {moves, body}
          {:speech, said} -> {moves ++ SayParser.parse(said), demeanor}
        end
      end)

    moves = moves |> Enum.with_index(1) |> Enum.map(fn {m, i} -> %Move{m | seq: i} end)
    {moves, %SelfState{demeanor: demeanor}}
  end

  defp classify(line) do
    trimmed = String.trim(line)

    cond do
      prefix?(trimmed, "thinks:") -> {:thought, strip(trimmed, "thinks:")}
      prefix?(trimmed, "does:") -> {:action, strip(trimmed, "does:")}
      prefix?(trimmed, "seems:") -> {:demeanor, strip(trimmed, "seems:")}
      true -> {:speech, line}
    end
  end

  defp prefix?(line, prefix), do: String.downcase(line) |> String.starts_with?(prefix)

  defp strip(line, prefix) do
    line |> binary_part(byte_size(prefix), byte_size(line) - byte_size(prefix)) |> String.trim()
  end
end
