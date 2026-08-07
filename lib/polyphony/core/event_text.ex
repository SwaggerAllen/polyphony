defmodule Polyphony.Core.EventText do
  @moduledoc """
  Renders (already-filtered) events to plain lines for LLM prompts — shared by
  the summarizer and arc extractor so a scene reads the same way to both.

  Interior events appear here only for the viewer whose they are (callers filter
  through `Polyphony.Core.Visibility` first), so rendering them is safe.
  """

  alias Polyphony.Events.{
    SpeechUttered,
    ActionTaken,
    WorldEventOccurred,
    ThoughtOccurred,
    DemeanorReported,
    CharacterEntered,
    CharacterExited
  }

  @doc "Render filtered events to a newline-joined transcript."
  @spec render(Enumerable.t()) :: String.t()
  def render(events) do
    events
    |> Enum.map(&line/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp line(%SpeechUttered{} = e), do: "#{e.speaker_id}: \"#{e.content}\""
  defp line(%ActionTaken{} = e), do: "#{e.character_id} #{e.content}"
  defp line(%WorldEventOccurred{} = e), do: "[#{e.content}]"
  defp line(%ThoughtOccurred{} = e), do: "(#{e.character_id} thinks: #{e.content})"
  defp line(%DemeanorReported{} = e), do: "[#{e.character_id}: #{e.demeanor}]"
  defp line(%CharacterEntered{} = e), do: "[#{e.character_id} enters]"
  defp line(%CharacterExited{} = e), do: "[#{e.character_id} leaves]"
  defp line(_), do: nil
end
