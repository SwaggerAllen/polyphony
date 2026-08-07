defmodule Polyphony.IngestTest do
  @moduledoc "User prose ingestion (§11): segmentation, verbatim integrity, OOC, self-state."
  use ExUnit.Case, async: true

  alias Polyphony.Ingest
  alias Polyphony.Ingest.Segment
  alias PolyphonyCore.TurnPacket
  alias PolyphonyCore.TurnPacket.SelfState

  describe "verbatim integrity (§11: never rewrite)" do
    test "verbatim spans in order pass" do
      source = "She said hello to the room"

      segs = [
        %Segment{type: :action, content: "She said"},
        %Segment{type: :speech, content: "hello"}
      ]

      assert :ok = Ingest.verify_verbatim(segs, source)
    end

    test "a rewritten span is rejected" do
      source = "She said hello"
      segs = [%Segment{type: :speech, content: "goodbye"}]

      assert {:error, {:not_verbatim, %Segment{content: "goodbye"}}} =
               Ingest.verify_verbatim(segs, source)
    end

    test "out-of-order spans are rejected (order is enforced)" do
      source = "She said hello"
      segs = [%Segment{type: :speech, content: "hello"}, %Segment{type: :action, content: "She"}]
      assert {:error, {:not_verbatim, _}} = Ingest.verify_verbatim(segs, source)
    end
  end

  describe "heuristic segmentation" do
    test "classifies quotes as speech, asterisks as action, [OOC:] as ooc" do
      prose = ~s(*She crosses the room* "We should leave" [OOC: keep it short])
      assert {:ok, parse} = Ingest.propose(prose)

      assert [
               %Segment{type: :action, content: "She crosses the room"},
               %Segment{type: :speech, content: "We should leave"},
               %Segment{type: :ooc, content: "keep it short"}
             ] = parse.segments
    end

    test "the produced segments are verbatim by construction" do
      prose = ~s(He paused. "Fine." *He turned away*)
      assert {:ok, parse} = Ingest.propose(prose)
      assert :ok = Ingest.verify_verbatim(parse.segments, prose)
    end
  end

  describe "a segmenter that rewrites is caught" do
    defmodule RewritingSegmenter do
      @behaviour Polyphony.Ingest.Segmenter
      def segment(_prose, _roster),
        do: {:ok, [%Segment{type: :speech, content: "an improved line"}]}
    end

    test "propose rejects it rather than committing an altered turn" do
      assert {:error, {:not_verbatim, _}} =
               Ingest.propose("the original line", segmenter: RewritingSegmenter)
    end
  end

  describe "propose/confirm flow" do
    test "confirm splits OOC out and builds a TurnPacket from the character moves" do
      prose = ~s(*steps inside* "Good evening" [OOC: end the scene soon])
      {:ok, parse} = Ingest.propose(prose)

      assert {:ok, %{packet: %TurnPacket{moves: moves}, ooc: ["end the scene soon"]}} =
               Ingest.confirm(parse)

      assert [
               %{seq: 1, type: :action, content: "steps inside"},
               %{seq: 2, type: :speech, content: "Good evening"}
             ] = Enum.map(moves, &Map.take(&1, [:seq, :type, :content]))
    end

    test "an edited segment that rewrites is rejected at confirm too" do
      {:ok, parse} = Ingest.propose(~s("hello"))
      bad = [%Segment{type: :speech, content: "totally different"}]
      assert {:error, {:not_verbatim, _}} = Ingest.confirm(parse, segments: bad)
    end
  end

  describe "self-state carry-forward (§11: user silence = unchanged)" do
    test "prior fields persist where the new state is silent" do
      previous = %SelfState{mood_felt: "calm", demeanor: "guarded", position: "by the door"}
      inferred = %SelfState{demeanor: "angry"}

      merged = Ingest.merge_self_state(previous, inferred)
      assert merged.demeanor == "angry"
      assert merged.mood_felt == "calm"
      assert merged.position == "by the door"
    end

    test "no inference carries the whole prior state forward" do
      previous = %SelfState{mood_felt: "wary"}
      assert Ingest.merge_self_state(previous, nil) == previous
    end
  end
end
