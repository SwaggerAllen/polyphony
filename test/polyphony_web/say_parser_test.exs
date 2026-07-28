defmodule PolyphonyWeb.SayParserTest do
  @moduledoc "Composer text → speech moves, inferring aloud vs. whisper from the text."
  use ExUnit.Case, async: true

  alias PolyphonyWeb.SayParser

  test "plain text is a single aloud speech move" do
    assert [
             %{
               type: :speech,
               content: "Hello there.",
               addressed_to: [],
               audibility: :normal,
               seq: 1
             }
           ] =
             SayParser.parse("Hello there.")
  end

  test "a whisper parenthetical becomes a private move addressed to the target" do
    assert [%{content: "meet me at dawn", addressed_to: ["Bram"], audibility: :private}] =
             SayParser.parse("(whisper to Bram: meet me at dawn)")
  end

  test "aloud and whisper mix in one submission, in order" do
    assert [aloud, whisper] =
             SayParser.parse("Nice to meet you. (whisper to Bram: I don't trust him)")

    assert aloud.audibility == :normal and aloud.content == "Nice to meet you."
    assert whisper.audibility == :private and whisper.addressed_to == ["Bram"]
    assert whisper.content == "I don't trust him"
    assert [aloud.seq, whisper.seq] == [1, 2]
  end

  test "aloud text on both sides of a whisper yields three ordered moves" do
    assert [a, w, b] = SayParser.parse("Hi all. (whisper Ana: run) See you.")
    assert a.content == "Hi all." and a.audibility == :normal
    assert w.audibility == :private and w.addressed_to == ["Ana"]
    assert b.content == "See you." and b.audibility == :normal
  end

  test "a whisper to several comma-separated names addresses each" do
    assert [%{addressed_to: ["Ana", "Bram"], audibility: :private}] =
             SayParser.parse("(whisper to Ana, Bram: hush)")
  end

  test "case-insensitive and empty/whitespace yields no moves" do
    assert [%{audibility: :private}] = SayParser.parse("(WHISPER TO Ana: hush)")
    assert SayParser.parse("   ") == []
    assert SayParser.parse("(whisper to Ana: )") == []
  end
end
