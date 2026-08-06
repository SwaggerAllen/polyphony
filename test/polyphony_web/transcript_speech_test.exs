defmodule PolyphonyWeb.TranscriptSpeechTest do
  @moduledoc """
  Telling speech from action in the reading register.

  In the working register a `Speech` label sits in the gutter, so the two moves are
  never confused. In the **reading** register there is no label — a character in their
  own head, and a published campaign, both render prose — and speech and action came out
  as the same paragraph at the same size. A page with no way to tell what was said from
  what was done, which is the one distinction fiction has always drawn typographically.

  The mocks quote every spoken line in both registers (`ux/polyphony-play.html` §01, §05);
  the port dropped it. Restoring it is the fix, and the two details worth pinning are
  that it doesn't double up on content that already arrives quoted, and that it
  normalises straight quotes — the model's punctuation habits are not a thing a reader
  should be able to see.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias Polyphony.Scene.Cast
  alias PolyphonyWeb.Transcript

  defp move(kind, payload), do: %{kind: kind, payload: payload}

  # A real `Cast` struct — the whisper line resolves ids through it, and a bare map
  # doesn't match `render_name/2`.
  defp render(m, register),
    do: m |> Transcript.render_move(%Cast{}, register, %{}) |> rendered_to_string()

  describe "said/1" do
    test "quotes a bare line" do
      assert Transcript.said("Nothing came in tonight.") == "“Nothing came in tonight.”"
    end

    test "leaves an already-quoted line alone rather than nesting" do
      assert Transcript.said("“Nothing came in tonight.”") == "“Nothing came in tonight.”"
    end

    test "normalises a straight-quoted line" do
      # Otherwise one provider's habit sits differently on the page beside another's.
      assert Transcript.said(~s("Nothing came in tonight.")) == "“Nothing came in tonight.”"
    end

    test "a quote inside a line is not the line being quoted" do
      said = Transcript.said(~s(He said "no" and left))
      assert said == ~s(“He said "no" and left”)
    end

    test "blank stays blank rather than becoming a pair of empty quotes" do
      assert Transcript.said("") == ""
      assert Transcript.said(nil) == ""
      assert Transcript.said("   ") == ""
    end

    test "a lone quote character isn't treated as a wrapper" do
      # `wrapped?` needs more than one character, or `"` unwraps to nothing.
      assert Transcript.said(~s(")) == ~s(“"”)
    end
  end

  describe "in the transcript" do
    test "the reading register can tell speech from action", %{} do
      speech = render(move("SpeechUttered", %{content: "Nothing came in tonight."}), :page)
      action = render(move("ActionTaken", %{content: "He writes nothing down."}), :page)

      assert speech =~ "“Nothing came in tonight.”"
      # The distinction is the quotes: both are the same paragraph otherwise, which is
      # the point — prose reads as prose, and punctuation carries the difference.
      refute action =~ "“"
      assert action =~ "He writes nothing down."
    end

    test "the working register keeps its label and gets the quotes too" do
      html = render(move("SpeechUttered", %{content: "Nothing came in tonight."}), :stage)

      # The mocks quote it in both, and one line reading two ways across registers is
      # how the same speech starts looking like two different kinds of move.
      assert html =~ "Speech"
      assert html =~ "“Nothing came in tonight.”"
    end

    test "a whisper is quoted like anything else, and still says who heard it" do
      html =
        render(
          move("SpeechUttered", %{
            content: "I burned the second page.",
            audibility: "private",
            addressed_to: ["bram"]
          }),
          :page
        )

      # Still speech. The whisper mark says who could hear it; the quotes say it was
      # said out loud at all, which is a different question.
      assert html =~ "“I burned the second page.”"
      assert html =~ "Whisper"
    end
  end

  describe "the whisper marker" do
    test "sits under the speech, not on the turn" do
      html =
        render(
          move("SpeechUttered", %{
            content: "I burned it.",
            audibility: "private",
            addressed_to: ["b"]
          }),
          :page
        )

      # The kit's own spec: *a coloured marker line under the speech*. A whisper is one
      # move, and a turn that contains one still has actions everybody watched —
      # `Visibility` has always been per-event, and this is the rendering catching up.
      assert html =~ "Whisper"
      assert html =~ "var(--pencil)"
      assert html =~ ~s(class="dot")
    end

    test "an action in the same turn is untouched by it" do
      # Nothing about a whisper reaches another move: the mark is rendered by the
      # speech clause and nothing else looks at `audibility`.
      html =
        render(
          move("ActionTaken", %{content: "He writes nothing down.", audibility: "private"}),
          :page
        )

      refute html =~ "Whisper"
      assert html =~ "He writes nothing down."
    end

    test "a private line is marked even when the addressees don't resolve" do
      html =
        render(move("SpeechUttered", %{content: "I burned it.", audibility: "private"}), :page)

      # It used to render nothing at all without names, which is the one direction that
      # must never happen: a private line reading as a public one.
      assert html =~ "Whisper"
    end

    test "ordinary speech carries no marker" do
      html = render(move("SpeechUttered", %{content: "Bring it over."}), :page)
      refute html =~ "Whisper"
    end
  end
end
