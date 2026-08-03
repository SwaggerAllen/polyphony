defmodule Polyphony.Authoring.CoverTest do
  @moduledoc """
  The cover (`backend-backlog.md` §2.12) — the one generation whose input
  deliberately exceeds its permitted output.

  Everywhere else the engine keeps a secret by never putting it in the prompt: a
  character isn't *told* what they can't know, so they can't leak it, and that is
  structural rather than instructed (`Polyphony.Visibility`, default-deny). The
  cover inverts it. The secrets are the input — they're what makes the blurb feel
  like it's about something — and the constraint lives in the prompt.

  So the two halves are pinned separately:

    * the secret really is in the prompt (otherwise the cover is written from half
      a character and reads like it), and
    * a cover that quotes one doesn't get returned.

  The guard catches verbatim quotation only, which the last test says out loud
  rather than leaving for someone to discover: paraphrase gets through, and no
  string check will ever catch it.
  """
  use ExUnit.Case, async: true

  alias Polyphony.Authoring.{Cover, CharacterSheet, WorldBible}
  alias Polyphony.Authoring.CharacterSheet.Fact

  @secret "Wren drowned the bellman in the spring and has rung for him every night since"

  defp wren do
    %CharacterSheet{
      name: "Wren Ashgrove",
      pronouns: "she / her",
      premise: "The bell-keeper of a town that stopped asking what the bell is for.",
      temperament: "Steady in company, sleepless alone.",
      facts: [
        %Fact{statement: "She keeps the tide bell on the harbour wall."},
        %Fact{statement: @secret, concealed: true}
      ]
    }
  end

  # A provider that records the prompt it saw and replies with `reply`.
  defp spy(reply) do
    me = self()

    fn messages ->
      send(me, {:prompt, Enum.map_join(messages, "\n", & &1.content)})
      {:ok, reply}
    end
  end

  defp opts(reply), do: [provider: Polyphony.LLM.Stub, respond_with: spy(reply)]

  defp prompt! do
    receive do
      {:prompt, text} -> text
    after
      0 -> flunk("the provider was never called")
    end
  end

  describe "what the model is shown" do
    test "the concealed fact is in the prompt — the cover is written from it" do
      assert {:ok, _} = Cover.generate(wren(), opts("A keeper, a bell, and a town that listens."))

      prompt = prompt!()
      assert prompt =~ @secret
      assert prompt =~ "must NOT give any of it away"
    end

    test "public facts are shown as public, secrets as secret" do
      assert {:ok, _} = Cover.generate(wren(), opts("Something in the harbour keeps time."))

      prompt = prompt!()
      assert prompt =~ "Known about them: She keeps the tide bell"
      assert prompt =~ "SECRET — informs the mood, must not be given away"
    end

    test "a world's hidden material is passed in by the caller" do
      world = %WorldBible{name: "Saltmarch", setting: "A drowned coast.", tone: "Elegiac"}
      hidden = "The sea wall was breached on purpose, by the council that built it"

      assert {:ok, _} =
               Cover.generate(
                 world,
                 [secrets: [hidden]] ++ opts("A coast that keeps its own counsel.")
               )

      prompt = prompt!()
      assert prompt =~ "role-play world"
      assert prompt =~ hidden
    end

    test "with nothing to hide, no secrecy instruction is spent" do
      plain = %CharacterSheet{name: "Halloran", premise: "A harbourmaster with clean books."}

      assert {:ok, _} =
               Cover.generate(plain, opts("He keeps the harbour, and the harbour keeps him."))

      refute prompt!() =~ "must NOT give any of it away"
    end
  end

  describe "the leak guard" do
    test "a seeded secret does not survive into the cover" do
      leaky = "Wren keeps the tide bell. " <> @secret <> ", which is why she cannot sleep."

      assert {:error, :leaked} = Cover.generate(wren(), opts(leaky))
    end

    test "a leak is retried once before it's given up on" do
      me = self()

      responder = fn _messages ->
        n = Process.get(:attempts, 0) + 1
        Process.put(:attempts, n)
        send(me, {:attempt, n})

        if n == 1,
          do: {:ok, "She rings for him. " <> @secret <> "."},
          else: {:ok, "A bell-keeper who rings on time, and never says for whom."}
      end

      assert {:ok, prose} =
               Cover.generate(wren(), provider: Polyphony.LLM.Stub, respond_with: responder)

      assert prose =~ "never says for whom"
      assert_received {:attempt, 1}
      assert_received {:attempt, 2}
    end

    test "the retry says what went wrong, so the second attempt isn't a coin flip" do
      me = self()

      responder = fn messages ->
        send(me, {:prompt, Enum.map_join(messages, "\n", & &1.content)})
        {:ok, @secret}
      end

      assert {:error, :leaked} =
               Cover.generate(wren(), provider: Polyphony.LLM.Stub, respond_with: responder)

      assert prompt!() =~ "must NOT give any of it away"
      assert prompt!() =~ "previous attempt quoted the secret material"
    end

    test "the check is on words, not bytes — casing and punctuation don't smuggle it through" do
      dressed = "\"" <> String.upcase(@secret) <> ",\" they say in Saltmarch."

      assert {:error, :leaked} = Cover.generate(wren(), opts(dressed))
    end

    test "a partial quotation of six words is still a quotation" do
      run = "drowned the bellman in the spring"
      assert Cover.leaks?("Everyone knows she #{run}, or says so.", [@secret])
    end

    test "an evocative cover that keeps the secret is returned unchanged" do
      good = "Every night the tide bell rings, and Wren Ashgrove is the one who rings it."

      assert {:ok, ^good} = Cover.generate(wren(), opts(good))
    end

    test "a short shared phrase is not a leak — this catches quotation, not overlap" do
      assert refute_leak("She keeps the tide bell.", [@secret])
      assert refute_leak("A town, a bell, and the spring.", [@secret])
    end

    test "paraphrase is NOT caught, and the prompt is what stands between it and the reader" do
      paraphrase =
        "She put a man under the water once, and the bell has been an apology ever since."

      # Deliberately asserted: the guard is a floor against regurgitation, not a
      # semantic filter. Anyone tightening it should know this line exists.
      assert {:ok, ^paraphrase} = Cover.generate(wren(), opts(paraphrase))
    end
  end

  describe "secrets_of/1" do
    test "a character's secrets are exactly their concealed facts" do
      assert Cover.secrets_of(wren()) == [@secret]
    end

    test "a world carries no concealment flag of its own yet" do
      assert Cover.secrets_of(%WorldBible{starting_canon: ["The sea wall holds."]}) == []
    end
  end

  defp refute_leak(prose, secrets), do: not Cover.leaks?(prose, secrets)
end
