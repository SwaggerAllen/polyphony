defmodule Polyphony.BuildsTest do
  @moduledoc """
  Quick Build after it stopped living in a socket.

  The bug this exists to end: the build ran in the campaign LiveView's `start_async`,
  so it died with the tab — and it died *after* it had written the world to the library
  and *before* anything associated it. What was left was an orphan world under exactly
  the name the author had just typed, so the next attempt collided with it and the world
  editor refused to save with nothing on screen to explain why. Three separate reports,
  one cause.

  So what's pinned here is the two properties that make that impossible rather than
  unlikely: **progress outlives the process that started it**, and **the campaign owns
  what has been built so far at every moment during the build**, not only at the end.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Builds, Library}
  alias Polyphony.Owner
  alias Polyphony.Authoring.{CharacterSheet, QuickBuild, WorldBible}
  alias Polyphony.Jobs.QuickBuild, as: BuildJob

  setup do
    previous = Application.get_env(:polyphony, :llm)
    Application.put_env(:polyphony, :llm, provider: Polyphony.LLM.Mock)
    on_exit(fn -> Application.put_env(:polyphony, :llm, previous) end)

    user = user_fixture()
    %{user: user, owner: Owner.of(user)}
  end

  defp campaign(owner, attrs \\ %{}) do
    payload =
      Map.merge(
        %{kind: :campaign, name: "Camp", character_ids: [], bible_id: nil, scenes: []},
        attrs
      )

    Library.put(%{owner: owner, kind: "campaign", payload: payload})
  end

  defp payload_of(id), do: Library.payload(Library.get(id))

  describe "the claim" do
    test "one campaign, one build", %{owner: owner} do
      camp = campaign(owner)

      assert {:ok, run} = Builds.claim(camp.id, 5)
      assert run.status == "running"

      # Taken in the database, not in the socket — because the socket is precisely the
      # thing that can't be trusted to still exist when the second tap arrives.
      assert :taken = Builds.claim(camp.id, 5)
      assert Builds.running?(camp.id)
    end

    test "a finished run releases the campaign for another", %{owner: owner} do
      camp = campaign(owner)
      {:ok, _} = Builds.claim(camp.id, 5)
      Builds.finish(camp.id, "Built a world.")

      refute Builds.running?(camp.id)
      assert {:ok, %{status: "running"}} = Builds.claim(camp.id, 5)
    end

    test "a failure is recorded rather than swept up", %{owner: owner} do
      camp = campaign(owner)
      {:ok, _} = Builds.claim(camp.id, 5)
      Builds.fail(camp.id, {:world_failed, :nope})

      # The author was probably not watching when it failed. A row that deleted itself
      # would be indistinguishable from a build that never started.
      assert %{status: "failed", detail: detail} = Builds.get(camp.id)
      assert detail =~ "The world couldn't be written"
    end
  end

  describe "progress" do
    test "survives the process that started it", %{owner: owner} do
      camp = campaign(owner)

      # Claim and report from a process that then dies — the socket, in effect.
      task =
        Task.async(fn ->
          {:ok, _} = Builds.claim(camp.id, 4)
          Builds.progress(camp.id, %{done: 2, total: 4, label: "Writing character 2 of 2"})
        end)

      Task.await(task)

      assert %{status: "running", step: 2, total: 4, label: "Writing character 2 of 2"} =
               Builds.get(camp.id)

      assert Builds.percent(Builds.get(camp.id)) == 50
    end

    test "is broadcast to whoever is watching", %{owner: owner} do
      camp = campaign(owner)
      Builds.subscribe(camp.id)

      {:ok, _} = Builds.claim(camp.id, 4)
      assert_receive {:build_progress, %{status: "running", step: 0}}

      Builds.progress(camp.id, %{done: 1, total: 4, label: "Dreaming up the world"})
      assert_receive {:build_progress, %{step: 1, label: "Dreaming up the world"}}

      Builds.finish(camp.id, "Built a world.")
      assert_receive {:build_progress, %{status: "done"}}
    end
  end

  describe "associating as it goes" do
    test "the world belongs to the campaign before the build finishes", %{owner: owner} do
      camp = campaign(owner)

      # Exactly the moment the old code got wrong: the world is persisted here, and the
      # association used to happen minutes later in a LiveView that might be gone.
      seen =
        QuickBuild.build(
          owner: owner,
          world_seed: "a rain-drowned harbour",
          character_seeds: ["a harbour-master"],
          on_entry: fn
            {:world, entry} ->
              # Assert *during* the build: by the time it returns, everything is
              # associated either way, so checking afterwards proves nothing.
              send(self(), {:world_at, entry.id, payload_of(camp.id)[:bible_id]})
              associate(camp.id, {:world, entry})

            other ->
              associate(camp.id, other)
          end
        )

      assert {:ok, _} = seen
      assert_received {:world_at, _id, nil}

      # And the campaign has it now — written by the callback, not by the return value.
      assert %WorldBible{} = payload_of(payload_of(camp.id)[:bible_id])
    end

    defp associate(campaign_id, {:world, entry}) do
      Library.update_payload(campaign_id, Map.put(payload_of(campaign_id), :bible_id, entry.id))
    end

    defp associate(campaign_id, {:character, entry}) do
      payload = payload_of(campaign_id)
      ids = (payload[:character_ids] || []) ++ [entry.id]
      Library.update_payload(campaign_id, Map.put(payload, :character_ids, Enum.uniq(ids)))
    end

    test "an interrupted build leaves a half-built campaign, not loose parts",
         %{owner: owner} do
      camp = campaign(owner)

      # Stop the build dead after the world is written — the shape of closing a tab,
      # except deterministic. Under the old code this is exactly where the orphan came
      # from.
      catch_throw(
        QuickBuild.build(
          owner: owner,
          world_seed: "a rain-drowned harbour",
          character_seeds: ["a harbour-master"],
          on_entry: fn
            {:world, entry} ->
              associate(camp.id, {:world, entry})
              throw(:interrupted)

            _ ->
              :ok
          end
        )
      )

      # The world exists and the campaign points at it. That's a campaign you can open
      # and finish — as opposed to a world in the library with nothing referencing it,
      # holding the name the author is about to try to use again.
      bible_id = payload_of(camp.id)[:bible_id]
      assert bible_id
      assert %WorldBible{} = payload_of(bible_id)

      # Which is the whole point: the name is not stranded, so the world editor has
      # nothing to refuse.
      refute Library.name_taken?(owner, "world_bible", payload_of(bible_id).name,
               except: bible_id
             )
    end
  end

  describe "resuming" do
    test "a second attempt keeps the world it already wrote", %{owner: owner} do
      camp = campaign(owner)

      # Attempt one gets as far as the world and stops.
      catch_throw(
        QuickBuild.build(
          owner: owner,
          world_seed: "a rain-drowned harbour",
          character_seeds: ["a harbour-master", "the collector"],
          on_entry: fn
            {:world, entry} ->
              associate(camp.id, {:world, entry})
              throw(:interrupted)

            _ ->
              :ok
          end
        )
      )

      bible_id = payload_of(camp.id)[:bible_id]
      before = payload_of(bible_id)

      # Attempt two, handed what exists. The world is not written again — which is the
      # difference between a retry that costs the remaining work and one that costs
      # everything twice and leaves two worlds behind.
      {:ok, result} =
        QuickBuild.build(
          owner: owner,
          world_seed: "a rain-drowned harbour",
          character_seeds: ["a harbour-master", "the collector"],
          resume: %{bible: Library.get(bible_id), done: [], characters: []}
        )

      assert result.bible.id == bible_id
      assert payload_of(bible_id).setting == before.setting

      assert Enum.count(Library.list_for_owner(owner), &(&1.kind == "world_bible")) == 1
    end

    test "a seed already written is not written twice", %{owner: owner} do
      camp = campaign(owner)
      seeds = ["a harbour-master", "the collector", "the bellman"]

      # Stop after the first character — the seed is recorded at the write, so the
      # resume knows about it.
      done = :ets.new(:done, [:public, :set])

      catch_throw(
        QuickBuild.build(
          owner: owner,
          world_seed: "a rain-drowned harbour",
          character_seeds: seeds,
          on_entry: &associate(camp.id, &1),
          on_seed_done: fn i ->
            :ets.insert(done, {i, true})
            throw(:interrupted)
          end
        )
      )

      first_pass = payload_of(camp.id)[:character_ids]
      assert length(first_pass) == 1
      assert :ets.lookup(done, 0) == [{0, true}]

      {:ok, result} =
        QuickBuild.build(
          owner: owner,
          world_seed: "a rain-drowned harbour",
          character_seeds: seeds,
          resume: %{
            bible: Library.get(payload_of(camp.id)[:bible_id]),
            done: [0],
            characters: Enum.map(first_pass, &Library.get/1)
          },
          on_entry: &associate(camp.id, &1)
        )

      # Three seeds, three characters — the first carried over rather than regenerated.
      # Never duplicating is worth more than finishing: a second Wren is a mess the
      # author has to notice and unpick, a missing one is a button away.
      assert length(result.characters) == 3
      assert hd(first_pass) in Enum.map(result.characters, & &1.id)
      assert length(payload_of(camp.id)[:character_ids]) == 3
    end

    test "a cover already written isn't paid for again", %{owner: owner} do
      entry =
        Library.put(%{
          owner: owner,
          kind: "world_bible",
          payload: %WorldBible{name: "Saltmarch", cover: "Already written."}
        })

      camp = campaign(owner, %{bible_id: entry.id})

      {:ok, _} =
        QuickBuild.build(
          owner: owner,
          world_seed: "",
          character_seeds: [],
          resume: %{bible: Library.get(entry.id), done: [], characters: []}
        )

      _ = camp
      assert payload_of(entry.id).cover == "Already written."
    end
  end

  describe "the job" do
    test "builds, associates, and reports done", %{owner: owner, user: user} do
      camp = campaign(owner)

      assert {:ok, %{status: "running"}} =
               BuildJob.enqueue(
                 owner: owner,
                 campaign_id: camp.id,
                 world_seed: "a rain-drowned harbour",
                 character_seeds: ["a harbour-master", "the collector"],
                 user_id: user.id
               )

      assert %{success: 1} = Oban.drain_queue(queue: :generation)

      payload = payload_of(camp.id)
      assert payload[:bible_id]
      assert length(payload[:character_ids]) == 2
      assert payload[:premise] not in [nil, ""]

      for id <- payload[:character_ids] do
        assert %CharacterSheet{status: :full} = payload_of(id)
      end

      assert %{status: "done", detail: detail} = Builds.get(camp.id)
      assert detail =~ "2 character(s)"
    end

    test "an attempt that dies mid-flight is picked up where it stopped",
         %{owner: owner, user: user} do
      camp = campaign(owner)

      assert {:ok, _} =
               BuildJob.enqueue(
                 owner: owner,
                 campaign_id: camp.id,
                 world_seed: "a rain-drowned harbour",
                 character_seeds: ["a harbour-master", "the collector"],
                 user_id: user.id
               )

      assert %{success: 1} = Oban.drain_queue(queue: :generation)
      built = payload_of(camp.id)[:character_ids]
      assert length(built) == 2

      # Start it again as a resume, the way the screen's "pick up where it stopped" does.
      # Everything is already written, so the second run adds nothing rather than a
      # second world and a second cast.
      assert {:ok, _} = BuildJob.retry(camp.id)
      assert %{success: 1} = Oban.drain_queue(queue: :generation)

      assert payload_of(camp.id)[:character_ids] == built
      assert Enum.count(Library.list_for_owner(owner), &(&1.kind == "world_bible")) == 1
    end

    test "walk-ons join the roster, and a resume doesn't mistake one for cast",
         %{owner: owner, user: user} do
      camp = campaign(owner)

      assert {:ok, _} =
               BuildJob.enqueue(
                 owner: owner,
                 campaign_id: camp.id,
                 world_seed: "a rain-drowned harbour",
                 character_seeds: ["a harbour-master"],
                 suggest_offscreen: true,
                 user_id: user.id
               )

      assert %{success: 1} = Oban.drain_queue(queue: :generation)

      roster = payload_of(camp.id)[:character_ids]
      sheets = Enum.map(roster, &payload_of/1)
      {cast, walk_ons} = Enum.split_with(sheets, &(&1.status == :full))

      assert length(cast) == 1
      assert walk_ons != [], "the people the cast introduced weren't put in the campaign"

      # The reason `resume_state` filters to `:full`. Handing the walk-ons back as built
      # cast would have the next attempt count them as seeds already done, cross-link
      # them into the main cast, and write them covers they aren't meant to have.
      assert {:ok, _} = BuildJob.retry(camp.id)
      assert %{success: 1} = Oban.drain_queue(queue: :generation)

      after_retry = Enum.map(payload_of(camp.id)[:character_ids], &payload_of/1)
      assert Enum.count(after_retry, &(&1.status == :full)) == 1
      assert Enum.all?(walk_ons, &(&1.cover in [nil, ""]))
    end

    test "refuses a second build for the same campaign", %{owner: owner} do
      camp = campaign(owner)

      assert {:ok, _} =
               BuildJob.enqueue(owner: owner, campaign_id: camp.id, character_seeds: [""])

      assert :taken = BuildJob.enqueue(owner: owner, campaign_id: camp.id, character_seeds: [""])
    end

    test "a total failure is recorded on the campaign's run", %{owner: owner} do
      Application.put_env(:polyphony, :llm,
        provider: Polyphony.LLM.Stub,
        stub_response: {:error, :nope}
      )

      camp = campaign(owner)

      assert {:ok, _} =
               BuildJob.enqueue(owner: owner, campaign_id: camp.id, character_seeds: [""])

      # Retried, then given up on. `max_attempts: 3` — a build is minutes of work and a
      # real bill, and a 502 four characters in is exactly what a retry is for.
      drain = fn -> Oban.drain_queue(queue: :generation, with_scheduled: true) end

      assert %{failure: 1} = drain.()
      # Still *running* between attempts: telling the author it failed and then quietly
      # starting again is worse than saying nothing.
      assert %{status: "running"} = Builds.get(camp.id)

      assert %{failure: 1} = drain.()
      assert %{status: "running"} = Builds.get(camp.id)

      # The last attempt records the failure and returns `:ok`, so the queue doesn't also
      # carry a discarded job for something the run row already explains.
      assert %{success: 1} = drain.()
      assert %{status: "failed"} = Builds.get(camp.id)
      assert payload_of(camp.id)[:bible_id] == nil
    end
  end
end
