defmodule Polyphony.QuickBuildGroupsTest do
  @moduledoc """
  Quick Build writing the collectives a world names, and putting the cast in them.

  A world bible full of crews, households and orders is a world where half the cast
  should start out sharing what that crew knows — and a group is exactly the thing the
  design provides for it: *written like a character, used as a starting point for
  others, and somewhere for a secret to point*. Written by hand it is a chore nobody
  does, and a cast written without them each invents a private version of the same
  institution.

  Two decisions are worth pinning. Groups are written **before the cast**, because a
  group is a starting point and one written afterwards has nobody left to seed. And a
  member is seeded **after** their sheet is generated, so `Group.seed/2` fills only what
  is missing — which in practice means the group's **facts**, the secrets belonging is
  defined to grant. That is the payoff: a Tidewatch member who starts out knowing what
  the Tidewatch knows, without anyone typing it five times.

  It is opt-in. It costs a provider call, and a two-hander needs no order or watch.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Groups, Library}
  alias Polyphony.Owner
  alias Polyphony.Authoring.{Group, QuickBuild}

  setup do
    previous = Application.get_env(:polyphony, :llm)
    on_exit(fn -> Application.put_env(:polyphony, :llm, previous) end)

    user = user_fixture()
    %{user: user, owner: Owner.of(user)}
  end

  @groups_prompt "Find the **collectives**"

  # One group claiming seed 0, with a secret — the shape the feature exists for.
  defp stub_provider(groups_json) do
    responder = fn messages ->
      prompt = Enum.map_join(messages, "\n", & &1.content)

      cond do
        String.contains?(prompt, @groups_prompt) ->
          {:ok, groups_json}

        String.contains?(prompt, "world bible for a role-play setting") ->
          {:ok, Jason.encode!(%{"name" => "Saltmarch", "setting" => "A tidal port."})}

        String.contains?(prompt, "role-play character") ->
          n = :erlang.unique_integer([:positive])
          {:ok, Jason.encode!(%{"name" => "Person #{n}", "premise" => "Someone #{n}."})}

        true ->
          {:ok, Jason.encode!(%{})}
      end
    end

    Application.put_env(:polyphony, :llm, provider: Polyphony.LLM.Stub, stub_response: responder)
  end

  defp one_group(members \\ [0]) do
    Jason.encode!([
      %{
        "name" => "The Tidewatch",
        "premise" => "They keep the harbour's ledgers.",
        "temperament" => "Closed ranks under pressure.",
        "facts" => [
          %{"statement" => "They meet at the third bell.", "concealed" => false},
          %{"statement" => "The ledger's second page is missing.", "concealed" => true}
        ],
        "members" => members
      }
    ])
  end

  defp build(owner, opts) do
    QuickBuild.build(
      [
        owner: owner,
        world_seed: "a rain-drowned harbour",
        character_seeds: ["a harbour-master", "the collector"],
        # Groups are scoped to a campaign (STR-68), and a build writes them, so a build
        # has to say which campaign it is building. `write_groups/7` fetches it rather
        # than defaulting, so a caller that forgets is told here and not three frames on.
        campaign_id: "camp"
      ] ++ opts
    )
  end

  test "off by default — nothing is written and nothing is asked for", %{owner: owner} do
    stub_provider(one_group())

    {:ok, result} = build(owner, [])

    assert result.groups == []
    assert Groups.list(owner) == []
  end

  test "on, it writes the group and puts the named seed in it", %{owner: owner} do
    stub_provider(one_group([0]))

    {:ok, result} = build(owner, groups: true)

    assert [%{entry: entry}] = result.groups
    assert %Group{name: "The Tidewatch"} = group = Library.payload(entry)

    # Tied to the world it was read out of, like a character is.
    assert group.world_bible_id == result.bible.id

    # The first seed is a member; the second was not named and is not forced in.
    [first, second] = result.characters
    assert Groups.member_ids(entry.id) == [to_string(first.id)]
    refute to_string(second.id) in Groups.member_ids(entry.id)
  end

  test "a member starts out holding the group's facts, secrets included",
       %{owner: owner} do
    stub_provider(one_group([0]))

    {:ok, result} = build(owner, groups: true)
    [first, second] = result.characters

    facts = Library.payload(Library.get(first.id)).facts
    statements = Enum.map(facts, & &1.statement)

    # The payoff. `Group.seed/2` appends the group's facts, and the concealed one
    # arrives concealed — knowing them is what belonging is defined to mean.
    assert "They meet at the third bell." in statements
    assert "The ledger's second page is missing." in statements

    assert Enum.any?(
             facts,
             &(&1.statement == "The ledger's second page is missing." and &1.concealed)
           )

    assert Enum.any?(
             facts,
             &(&1.statement == "They meet at the third bell." and not &1.concealed)
           )

    # And somebody who isn't in it doesn't know any of it.
    outsider = Enum.map(Library.payload(Library.get(second.id)).facts || [], & &1.statement)
    refute "The ledger's second page is missing." in outsider
  end

  test "seeding never overwrites what the sheet already says", %{owner: owner} do
    stub_provider(one_group([0]))

    {:ok, result} = build(owner, groups: true)
    [first | _] = result.characters
    sheet = Library.payload(Library.get(first.id))

    # The generated premise is the character's own; the group is a starting point, and
    # a starting point that overwrote a written field would be a second author.
    assert sheet.premise =~ "Someone"
    refute sheet.premise == "They keep the harbour's ledgers."
    # What was missing is filled: nothing generated a temperament here.
    assert sheet.temperament == "Closed ranks under pressure."
  end

  test "a hallucinated member index can't reach a character who doesn't exist",
       %{owner: owner} do
    stub_provider(one_group([0, 7, -1]))

    {:ok, result} = build(owner, groups: true)
    [%{entry: entry}] = result.groups

    # Two seeds were sent, so 7 and -1 are not people. Clamped at the boundary rather
    # than left to crash the walk halfway through a paid build.
    assert Groups.member_ids(entry.id) == [to_string(hd(result.characters).id)]
  end

  test "a provider that can't answer leaves the cast unbuilt-from rather than unbuilt",
       %{owner: owner} do
    stub_provider("not json at all")

    {:ok, result} = build(owner, groups: true)

    # Best-effort, like every phase after the world: no groups, and a cast that still
    # exists. A build that produced a world and two characters must not be thrown away
    # because an optional extra failed.
    assert result.groups == []
    assert length(result.characters) == 2
  end

  test "the prompt is given the seeds by index, so a blank one can be placed",
       %{owner: owner} do
    test = self()

    Application.put_env(:polyphony, :llm,
      provider: Polyphony.LLM.Stub,
      stub_response: fn messages ->
        prompt = Enum.map_join(messages, "\n", & &1.content)
        if String.contains?(prompt, @groups_prompt), do: send(test, {:groups_prompt, prompt})
        {:ok, Jason.encode!(%{})}
      end
    )

    {:ok, _} =
      QuickBuild.build(
        owner: owner,
        world_seed: "a rain-drowned harbour",
        character_seeds: ["a harbour-master", ""],
        groups: true
      )

    assert_received {:groups_prompt, prompt}
    assert prompt =~ "The cast about to be written, by index:"
    assert prompt =~ "0: a harbour-master"
    # A blank seed is still a person to place — saying so is what stops it being skipped.
    assert prompt =~ "1: (no brief"
  end
end
