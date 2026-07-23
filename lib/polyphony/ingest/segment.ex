defmodule Polyphony.Ingest.Segment do
  @moduledoc """
  One classified span of the user's prose (§11 ingestion).

  Ingestion is **segmentation, not generation**: the prose already exists, so a
  segment's `content` is a *verbatim span of the source* — never a rewrite. The
  parse splits and classifies; `Polyphony.Ingest.verify_verbatim/2` is the gate
  that enforces it for any segmenter, LLM or heuristic.
  """
  @derive Jason.Encoder
  defstruct [:type, :content, addressed_to: [], audibility: :normal, proposal: nil]

  @type type :: :speech | :action | :thought | :ooc
  @type t :: %__MODULE__{
          type: type(),
          content: String.t(),
          addressed_to: [term()],
          audibility: :normal | :private,
          proposal: map() | nil
        }
end
