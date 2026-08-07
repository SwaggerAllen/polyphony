defmodule Polyphony.WorldSecretsTest do
  @moduledoc """
  A secret in the world bible, and the one place it must never reach.

  `ux/polyphony-world.html` §04 asks for one secret control in three places — a rule,
  a canon entry, a character's fact — and says a secret stays *out of the cover, out
  of browse, and out of any perspective that shouldn't have it.* Two of those three
  are visible failures. The third is not: a concealed world fact that reaches a
  character's prompt leaks **into the generation**, where nobody can see it happen and
  the only symptom is a character who mysteriously knows something.

  So the split is structural rather than instructed, in the same shape `Visibility`
  draws for events:

    * a **character** reads `WorldBible.public/1` — concealed rules and canon are
      simply absent from the prefix;
    * the **Director** reads `statements/1` and sees everything, because knowing a
      secret is how it aims a scene at one;
    * anything that *writes a character* — a stub, a generated sheet — is
      character-facing too. Being written *from* a secret is how a character comes to
      know it, which is the same leak one step earlier.

  Concealment is deliberately **not** the same axis as world-arc reach. `scope`
  answers *where a fact landed*; `concealed` answers *who knows it*. Folding them
  together would make a local fact secret and a global secret impossible.
  """
  use ExUnit.Case, async: true

  alias Polyphony.{Context, Director}
  alias Polyphony.Authoring.Knowledge
  alias Polyphony.Authoring.{CharacterSheet, WorldBible, WorldArcEntry, EffectiveWorldBible}
  alias Polyphony.Authoring.WorldBible.Entry

  @secret "The harbourmaster has been paid to lose paperwork since before his daughter was born."
  @public "Nobody in Saltmarch has seen a customs inspector in nine years."
  @secret_rule "The tide bell is rung twice when a debt is called in."

  defp bible do
    %WorldBible{
      name: "Saltmarch",
      setting: "A port town on a tidal flat.",
      rules: [
        %Entry{statement: "No magic. What looks like it is a bribe."},
        %Entry{statement: @secret_rule, concealed: true}
      ],
      starting_canon: [
        %Entry{statement: @public},
        %Entry{statement: @secret, concealed: true}
      ]
    }
  end

  defp character_prefix(bible) do
    Context.materialize(%{
      scene_id: "S1",
      character_id: "wren",
      sheet: %CharacterSheet{name: "Wren"},
      world_bible: bible
    }).prefix
  end

  describe "what a character is told" do
    test "a concealed canon entry never reaches their prefix" do
      prefix = character_prefix(bible())

      assert prefix =~ @public
      refute prefix =~ @secret
    end

    test "a concealed rule doesn't either — rules go to everyone, so this is the same hole" do
      prefix = character_prefix(bible())

      assert prefix =~ "No magic."
      refute prefix =~ @secret_rule
    end

    test "a bible whose lists are all concealed renders no Canon block at all" do
      all_secret = %WorldBible{
        name: "Saltmarch",
        starting_canon: [%Entry{statement: @secret, concealed: true}]
      }

      prefix = character_prefix(all_secret)
      assert prefix =~ "World: Saltmarch"
      refute prefix =~ "Canon:"
    end
  end

  describe "what the Director is told" do
    test "everything, because knowing a secret is how it aims a scene at one" do
      brief = Director.SceneBrief.materialize("S1", world_bible: bible()).prefix

      assert brief =~ @secret
      assert brief =~ @secret_rule
      assert brief =~ @public
    end
  end

  describe "the two axes stay apart" do
    test "world-arc reach is about where a fact landed, not who knows it" do
      arc = [
        %WorldArcEntry{
          kind: :discovery,
          statement: "The gates broke.",
          status: :canon,
          scope: :global
        }
      ]

      folded = EffectiveWorldBible.apply(bible(), arc, :all)

      # The arc fact folds in as public — it reached whoever was in reach of it.
      assert "The gates broke." in WorldBible.public(folded.starting_canon)
      # And the authored secret is still a secret after folding.
      refute @secret in WorldBible.public(folded.starting_canon)
      assert @secret in WorldBible.statements(folded.starting_canon)
    end
  end

  describe "the accessors" do
    test "a bare string is a public entry — old payloads and generated lines both work" do
      loose = %WorldBible{rules: ["Debts outlive the people who owe them."]}

      assert WorldBible.public(loose.rules) == ["Debts outlive the people who owe them."]
      assert WorldBible.statements(loose.rules) == ["Debts outlive the people who owe them."]
    end

    test "a form's string-keyed map round-trips its flag" do
      assert %Entry{statement: "x", concealed: true} =
               Entry.from(%{"statement" => "x", "concealed" => "true"})

      assert %Entry{concealed: false} = Entry.from(%{"statement" => "x"})
    end

    test "secrets/1 gathers both lists — a cover has to be checked against all of them" do
      assert Enum.sort(WorldBible.secrets(bible())) == Enum.sort([@secret_rule, @secret])
    end

    test "for_character/1 is the same filter, so a preview shows what a prompt gets" do
      previewed = Knowledge.for_character(bible())

      assert WorldBible.statements(previewed.starting_canon) == [@public]

      assert WorldBible.statements(previewed.rules) == [
               "No magic. What looks like it is a bribe."
             ]

      # And it is the *same* answer the context path gives.
      prefix = character_prefix(bible())
      for s <- WorldBible.statements(previewed.starting_canon), do: assert(prefix =~ s)
    end
  end

  describe "generating a character from the world" do
    @tag :repo
    test "grounds them in the public world only — being written from a secret is knowing it" do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Polyphony.Repo)
      owner = Polyphony.Owner.coerce(System.unique_integer([:positive]))

      entry =
        Polyphony.Library.put(%{owner: owner, kind: "world_bible", payload: bible()})

      ctx = Polyphony.Authoring.StubGen.world_context(entry.id)

      assert ctx["starting_canon"] =~ @public
      refute ctx["starting_canon"] =~ @secret
      refute ctx["rules"] =~ @secret_rule
    end
  end
end
