defmodule Polyphony.ContextTest do
  @moduledoc """
  The context assembler (§9): the caching discipline and the filtered-view guard.
  Pure — no LLM, no DB, retrieval injected.
  """
  use ExUnit.Case, async: true

  alias Polyphony.Context
  alias Polyphony.Authoring.{WorldBible, CharacterSheet}
  alias Polyphony.Authoring.CharacterSheet.Fact
  import Polyphony.Test.Scenario

  # A retriever that records how many times it was consulted, so we can prove
  # retrieval runs once at scene open and never per turn.
  defmodule SpyRetriever do
    @behaviour Polyphony.Context.Retriever
    def rank_facts(f, _p, _o), do: bump(:facts) && f

    def fetch_summaries(_scope, _p, opts),
      do: bump(:summaries) && Keyword.get(opts, :summaries, [])

    defp bump(k), do: Process.put({:spy, k}, (Process.get({:spy, k}) || 0) + 1) || true
  end

  defp sheet do
    %CharacterSheet{
      name: "Mira",
      premise: "A guarded envoy.",
      voice: "clipped, formal",
      temperament: "wary",
      initial_knowledge: ["the duke is ill"],
      facts: [
        %Fact{statement: "keeps a dagger in her sleeve", core: true},
        %Fact{statement: "once studied in the capital", core: false}
      ]
    }
  end

  defp materialize(extra) do
    base = %{
      scene_id: "S1",
      character_id: "mira",
      sheet: sheet(),
      premise: "The envoy arrives at a locked gate.",
      world_bible: %WorldBible{name: "Aldath", rules: ["no magic", "iron is scarce"]}
    }

    Context.materialize(Map.merge(base, Map.new(extra)))
  end

  describe "the frozen prefix (cache unit)" do
    test "is byte-identical across packets regardless of live history" do
      ctx = materialize([])

      m1 = Context.to_messages(ctx, live_events: [speech("otto", "S1", 1, "Who goes there?")])

      m2 =
        Context.to_messages(ctx,
          live_events: [
            speech("otto", "S1", 1, "Who goes there?"),
            speech("mira", "S1", 2, "An envoy.")
          ]
        )

      [%{role: "system", content: p1} | _] = m1
      [%{role: "system", content: p2} | _] = m2

      assert p1 == p2, "the cached prefix must not change turn to turn"
      assert p1 == ctx.prefix
    end

    test "contains the bible rules, effective sheet, and core facts" do
      ctx = materialize([])
      assert ctx.prefix =~ "no magic"
      assert ctx.prefix =~ "clipped, formal"
      assert ctx.prefix =~ "keeps a dagger in her sleeve"
      assert ctx.prefix =~ "the duke is ill"
    end

    test "retrieval runs exactly once, at scene open — not per packet" do
      ctx = materialize(retriever: SpyRetriever)
      assert Process.get({:spy, :facts}) == 1
      assert Process.get({:spy, :summaries}) == 1

      _ = Context.to_messages(ctx, live_events: [speech("otto", "S1", 1, "hi")])
      _ = Context.to_messages(ctx, live_events: [])

      assert Process.get({:spy, :facts}) == 1, "to_messages must not re-run retrieval"
      assert Process.get({:spy, :summaries}) == 1
    end
  end

  describe "filtered-view guard (§8)" do
    test "a character's live context never contains another character's thoughts" do
      ctx = materialize([])

      live = [
        entered("S1", "mira", 1),
        entered("S1", "otto", 1),
        thought("otto", "S1", 2, "SECRET-PLAN-do-not-leak"),
        speech("otto", "S1", 2, "Lovely weather.")
      ]

      [_system, %{content: user}] =
        Context.to_messages(ctx, live_events: live, members: ["mira", "otto"])

      assert user =~ "Lovely weather."
      refute user =~ "SECRET-PLAN-do-not-leak"
    end

    test "verbatim recent scenes are filtered to this character's view" do
      recent = [
        %{
          scene_id: "S0",
          events: [
            entered("S0", "mira", 1),
            entered("S0", "otto", 1),
            thought("otto", "S0", 2, "PRIOR-SECRET"),
            speech("otto", "S0", 2, "We should talk.")
          ]
        }
      ]

      ctx = materialize(recent_scenes: recent)

      assert ctx.prefix =~ "We should talk."
      refute ctx.prefix =~ "PRIOR-SECRET"
    end
  end

  describe "memory gradient (§9)" do
    test "a scene included verbatim is not also included as a summary (dedup)" do
      recent = [
        %{
          scene_id: "S0",
          events: [entered("S0", "mira", 1), speech("mira", "S0", 1, "verbatim line")]
        }
      ]

      summaries = [
        %{scene_id: "S0", text: "SUMMARY-OF-S0-should-be-deduped"},
        %{scene_id: "S-distant", text: "SUMMARY-OF-DISTANT-kept"}
      ]

      ctx = materialize(recent_scenes: recent, distant_summaries: summaries)

      assert ctx.prefix =~ "SUMMARY-OF-DISTANT-kept"
      refute ctx.prefix =~ "SUMMARY-OF-S0-should-be-deduped"
    end

    test "verbatim scenes are budgeted by tokens, dropping oldest-first" do
      long_body = for i <- 1..60, do: speech("mira", "old", i, "old chatter line number #{i}")

      recent = [
        %{scene_id: "old", events: [entered("old", "mira", 0) | long_body]},
        %{
          scene_id: "new",
          events: [entered("new", "mira", 0), speech("mira", "new", 1, "NEWLINE")]
        }
      ]

      ctx = materialize(recent_scenes: recent, scene_token_budget: 50)

      assert ctx.prefix =~ "NEWLINE", "the most recent scene survives"
      refute ctx.prefix =~ "old chatter line number 1", "the oldest scene is dropped first"
    end
  end

  describe "message structure" do
    test "premise, membership, and exits land in the volatile suffix" do
      ctx = materialize([])

      [_system, %{content: user}] =
        Context.to_messages(ctx, members: ["mira", "otto"], exits: ["north gate", "courtyard"])

      assert user =~ "The envoy arrives at a locked gate."
      assert user =~ "Present: mira, otto"
      assert user =~ "Exits: north gate, courtyard"
    end

    test "the authored location lands in the volatile suffix, not the cached prefix (§2.3)" do
      ctx = materialize(location: "The North Dock at dawn")

      # Scene-scoped, so it rides the volatile suffix — never the byte-stable prefix, or
      # every new scene would invalidate the cast's cached prefix.
      refute ctx.prefix =~ "The North Dock at dawn"

      [_system, %{content: user}] = Context.to_messages(ctx, members: ["mira"])
      assert user =~ "Location: The North Dock at dawn"
    end

    test "a blank location renders nothing (§2.3)" do
      ctx = materialize(location: "  ")
      assert ctx.location == nil

      [_system, %{content: user}] = Context.to_messages(ctx, members: ["mira"])
      refute user =~ "Location:"
    end
  end
end
