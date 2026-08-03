defmodule Polyphony.Reading.Bookmark do
  @moduledoc """
  A reader's place in a published campaign (§3.1e).

  Three fields, and the third is the one that's easy to leave out: **perspective is
  part of where you were**. A published campaign grants a set of reading perspectives,
  and coming back into a different head is coming back to a different story — so the
  bookmark carries it alongside the scene and the beat.

  `perspective` is a **character id** (the library entry id, the routing key
  everywhere) or `:omniscient`. Never a name — the same rule that holds in visibility,
  membership and packet ids holds here.

  `published_id` points at the **frozen published entry**, not the author's live
  campaign. That's the independence guarantee of §B1 read from the other end: a reader
  is holding a reference to the thing they were shown, which cannot be edited under
  them, and which they keep a place in even after it stops being visible.
  """

  @derive Jason.Encoder
  defstruct published_id: nil,
            scene_id: nil,
            beat: nil,
            perspective: :omniscient,
            last_read_at: nil,
            finished_at: nil

  @type t :: %__MODULE__{
          published_id: term(),
          scene_id: term(),
          beat: integer() | nil,
          perspective: term(),
          last_read_at: NaiveDateTime.t() | nil,
          finished_at: NaiveDateTime.t() | nil
        }
end
