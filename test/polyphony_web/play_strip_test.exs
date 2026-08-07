defmodule PolyphonyWeb.Play.StripTest do
  @moduledoc """
  The status strip says what's happening in the beat.

  Two things are pinned: each beat outcome maps to the slot state the kit assigns
  it, and the sentence reads from the viewer's position.

  The third — that **every member of the beat gets a slot, for every viewer** — is
  pinned deliberately, because the obvious instinct is to filter it. Presence is
  currently binary and symmetric, so there is no character who is in a scene but
  unknown to the people in it; filtering would model a distinction the domain
  doesn't have, and would cost a player the thing the strip is for, which is seeing
  that the beat is moving rather than hung. Concealed presence is specced
  (Linear `STR-17`/`STR-18`) and gets a greyed placeholder here rather than an
  omission, landing together with the context-generation half.
  """
  use ExUnit.Case, async: true

  alias PolyphonyCore.Events.{BeatOpened, PacketFailed, PacketPassed, PacketRecorded}
  alias PolyphonyWeb.Play.Strip

  @names %{"1" => "Wren Ashgrove", "2" => "Ilias", "3" => "Corrigan", "4" => "Sable"}
  @voices %{"1" => "var(--v1)", "2" => "var(--v2)", "3" => "var(--v3)"}

  defp opened(cast), do: [%BeatOpened{beat_ref: "s-b1", scene_id: "s", beat: 1, cast: cast}]

  defp build(events, opts) do
    Strip.build(
      Keyword.merge(
        [
          beat_events: events,
          names: @names,
          voices: @voices,
          members: ["1", "2", "3"]
        ],
        opts
      )
    )
  end

  defp states(strip), do: Enum.map(strip.slots, &{&1.id, &1.state})

  describe "slots" do
    test "each beat outcome takes the state the kit assigns it" do
      events =
        opened(["1", "2", "3"]) ++
          [
            %PacketRecorded{beat_ref: "s-b1", character_id: "1"},
            %PacketPassed{beat_ref: "s-b1", character_id: "2"},
            %PacketFailed{beat_ref: "s-b1", character_id: "3", reason: "empty"}
          ]

      assert states(build(events, viewer: :omniscient)) ==
               [{"1", :took}, {"2", :pass}, {"3", :fail}]
    end

    test "whoever is generating right now is the live slot" do
      strip = build(opened(["1", "2"]), viewer: :omniscient, generating: "2")

      assert states(strip) == [{"1", :wait}, {"2", :now}]
    end

    test "only a taken turn is filled with the character's voice" do
      events = opened(["1", "2"]) ++ [%PacketRecorded{beat_ref: "s-b1", character_id: "1"}]
      [took, waiting] = build(events, viewer: :omniscient).slots

      # Five states rendered in five colours would read as one; the kit carries the
      # rest with borders, so the hue means "this is theirs, and they went".
      assert took.colour == "var(--v1)"
      refute waiting.colour
    end

    test "the viewer's own slot is marked, and only theirs" do
      strip = build(opened(["1", "2", "3"]), viewer: {:character, "2"})

      assert Enum.filter(strip.slots, & &1.you) |> Enum.map(& &1.id) == ["2"]
    end

    test "a declared turn order wins over the beat's opening cast" do
      # A GM reorder is authoritative (§A1) — the strip has to agree with the order
      # the walk will actually take, or it lies about who is next.
      strip = build(opened(["1", "2", "3"]), viewer: :omniscient, order: ["3", "1", "2"])

      assert Enum.map(strip.slots, & &1.id) == ["3", "1", "2"]
    end

    test "labels shorten to initials on demand" do
      strip = build(opened(["1", "3"]), viewer: :omniscient)

      # The first word, not the first four characters — "Wren Ashgrove" is WREN.
      assert Enum.map(strip.slots, & &1.label) == ["WREN", "CORRI"]
      assert Enum.map(Strip.to_initials(strip).slots, & &1.label) == ["W", "C"]
    end
  end

  describe "who gets a slot" do
    test "everyone in the beat, whoever is looking" do
      # Not filtered per viewer: nothing in the domain can be present-but-unknown,
      # so a filter would invent a distinction — and blank slots are how a player
      # tells a moving beat from a hung one.
      for viewer <- [:omniscient, {:character, "2"}] do
        strip = build(opened(["1", "2", "4"]), viewer: viewer, members: ["1", "2"])

        assert Enum.map(strip.slots, & &1.id) == ["1", "2", "4"]
      end
    end

    test "before a beat opens, the room is the cast" do
      # A scene that has been set up but not run should still show who is in it,
      # rather than an empty tracker.
      strip = build([], viewer: {:character, "2"}, members: ["1", "2", "3"])

      assert Enum.map(strip.slots, & &1.id) == ["1", "2", "3"]
    end
  end

  describe "the sentence" do
    test "names the viewer's own turn, in lamp" do
      strip = build(opened(["1", "2"]), viewer: {:character, "2"}, generating: "2")

      assert strip.sentence == "Your turn."
      assert strip.tone == "var(--lamp)"
    end

    test "says how long until yours rather than making you count" do
      order = ["1", "3", "2"]

      strip = build(opened(order), viewer: {:character, "2"}, order: order, generating: "1")
      assert strip.sentence == "Wren Ashgrove is writing. One turn until yours."

      strip = build(opened(order), viewer: {:character, "3"}, order: order, generating: "1")
      assert strip.sentence == "Wren Ashgrove is writing. You're next."
    end

    test "a failure takes the line, in pencil" do
      events =
        opened(["1", "3"]) ++ [%PacketFailed{beat_ref: "s-b1", character_id: "3", reason: "x"}]

      strip = build(events, viewer: {:character, "1"})

      assert strip.sentence == "Corrigan's turn didn't come through."
      assert strip.tone == "var(--pencil)"
    end

    test "reads differently for the GM than for a player" do
      events = opened(["1", "2"]) ++ [%PacketRecorded{beat_ref: "s-b1", character_id: "1"}]

      assert build(events, viewer: :omniscient).sentence == "Waiting on Ilias."
      assert build(events, viewer: {:character, "1"}).sentence =~ "You've taken your turn."
    end

    test "an empty strip says nothing rather than something wrong" do
      assert build([], viewer: :omniscient, members: []).sentence == nil
    end

    test "carries no beat number — the transcript rule owns that" do
      events = opened(["1", "2"]) ++ [%PacketRecorded{beat_ref: "s-b1", character_id: "1"}]

      for viewer <- [:omniscient, {:character, "1"}] do
        refute build(events, viewer: viewer).sentence =~ ~r/beat/i
      end
    end
  end
end
