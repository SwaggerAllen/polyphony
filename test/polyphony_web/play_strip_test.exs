defmodule PolyphonyWeb.Play.StripTest do
  @moduledoc """
  The status strip says what's happening, and never more than the viewer knows.

  Two things are being pinned. The ordinary one is that each beat state maps to the
  slot the kit assigns it, and that the sentence reads from the viewer's position.

  The one that matters is the filter. The strip is a *summary* of the cast, which
  makes it a place dramatic irony can leak without any event leaking: a character
  who hasn't met someone must not learn they exist from a row of slots. So it is
  filtered like the transcript, and when membership can't answer it shows less
  rather than more — the same default-deny reasoning as `Polyphony.Visibility`.
  """
  use ExUnit.Case, async: true

  alias Polyphony.Events.{BeatOpened, PacketFailed, PacketPassed, PacketRecorded}
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

  describe "the filter" do
    test "a character sees only the cast they're in the room with" do
      # Sable is in the beat's cast but not a member the viewer shares the scene
      # with — so she must not appear, or the strip has told Ilias she exists.
      strip =
        build(opened(["1", "2", "4"]),
          viewer: {:character, "2"},
          members: ["1", "2"]
        )

      assert Enum.map(strip.slots, & &1.id) == ["1", "2"]
      refute strip.sentence =~ "Sable"
    end

    test "omniscient sees everyone" do
      strip = build(opened(["1", "2", "4"]), viewer: :omniscient, members: ["1", "2"])

      assert Enum.map(strip.slots, & &1.id) == ["1", "2", "4"]
    end

    test "when membership can't answer, a character sees only themselves" do
      # Failing open here would hand a viewer the whole cast list on a scene whose
      # membership hasn't resolved. Failing closed costs them a slot row.
      strip = build(opened(["1", "2", "4"]), viewer: {:character, "2"}, members: [])

      assert Enum.map(strip.slots, & &1.id) == ["2"]
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
