defmodule Polyphony.QuickBuildNamingTest do
  @moduledoc """
  Quick Build names the campaign it builds.

  It wrote a world, a cast, their relationships, a premise and five covers, and left the
  one field on the library row blank — so the thing the author sees first, and the thing
  that identifies the story everywhere, was the only part still saying "Untitled
  campaign". The fix is a word in the call that was already being made: a title is a
  *read* on the premise, not a separate creative act, and asked for on its own it has
  only the world seed and hands back the setting's name.

  The rule that keeps it safe is that it fills a **blank** and nothing else. Everything
  Quick Build does to a campaign is additive; renaming somebody's story out from under
  them would be the first thing that isn't.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Builds, Library, Owner}
  alias Polyphony.Authoring.QuickBuild
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
        %{kind: :campaign, name: "", character_ids: [], bible_id: nil, scenes: []},
        attrs
      )

    Library.put(%{owner: owner, kind: "campaign", payload: payload})
  end

  defp payload_of(id), do: Library.payload(Library.get(id))

  defp build(camp, owner, user) do
    assert {:ok, _} =
             BuildJob.enqueue(
               owner: owner,
               campaign_id: camp.id,
               world_seed: "a rain-drowned harbour",
               character_seeds: ["a harbour-master"],
               user_id: user.id
             )

    assert %{success: 1} = Oban.drain_queue(queue: :generation)
    assert %{status: "done"} = Builds.get(camp.id)
  end

  test "a blank campaign comes back named", %{owner: owner, user: user} do
    camp = campaign(owner)
    build(camp, owner, user)

    payload = payload_of(camp.id)
    assert String.trim(to_string(payload[:name])) != ""
    # Still the same call, so the premise is unaffected by having asked for both.
    assert payload[:premise] not in [nil, ""]
  end

  test "a campaign the author already titled keeps its title", %{owner: owner, user: user} do
    camp = campaign(owner, %{name: "The Salt Line"})
    build(camp, owner, user)

    assert payload_of(camp.id)[:name] == "The Salt Line"
    # And the rest of the build still landed — the name is skipped, not the phase.
    assert payload_of(camp.id)[:premise] not in [nil, ""]
  end

  test "the name comes back from the build itself, beside the premise", %{owner: owner} do
    assert {:ok, result} =
             QuickBuild.build(
               owner: owner,
               world_seed: "a rain-drowned harbour",
               character_seeds: ["a harbour-master"]
             )

    assert is_binary(result.name) and result.name != ""
    assert is_binary(result.premise) and result.premise != ""
  end

  test "a provider that can't answer leaves the campaign as it was", %{owner: owner, user: user} do
    camp = campaign(owner, %{name: "Kept"})

    # The opening call is best-effort like every other late phase: a blank name means
    # "nothing to attach", which is the same branch an author-set name takes.
    Application.put_env(:polyphony, :llm,
      provider: Polyphony.LLM.Stub,
      stub_response: fn messages ->
        prompt = Enum.map_join(messages, "\n", & &1.content)

        if String.contains?(prompt, "Give it a **name** and a **premise**"),
          do: {:error, :nope},
          else: {:ok, Jason.encode!(%{"name" => "X", "setting" => "Y", "premise" => "Z."})}
      end
    )

    build(camp, owner, user)
    assert payload_of(camp.id)[:name] == "Kept"
  end
end
