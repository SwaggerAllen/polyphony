defmodule Polyphony.Ingest.Segmenter do
  @moduledoc """
  The segmentation boundary (§11). A segmenter splits the user's prose into
  ordered `Segment`s, preserving the words verbatim.

  Two implementations share this behaviour: `HeuristicSegmenter` (deterministic,
  no LLM — quotes/asterisks/OOC conventions) and, later, a small-model LLM
  segmenter that resolves pronouns against the roster. Whatever produces the
  segments, `Polyphony.Ingest.verify_verbatim/2` checks them — a model given
  prose and a schema will "improve" it, and the user will notice and hate it.
  """

  @type roster :: [%{id: term(), name: String.t()}]

  @callback segment(prose :: String.t(), roster()) ::
              {:ok, [Polyphony.Ingest.Segment.t()]} | {:error, term()}
end
