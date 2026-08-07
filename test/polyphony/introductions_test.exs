defmodule Polyphony.IntroductionsTest do
  @moduledoc """
  The Director introduction primitive (§B7): proposing a character on-stage is a
  queue signal, not membership, and — critically — it is omniscient-only, so an
  in-scene character can never learn about someone before they formally enter.
  """
  use ExUnit.Case, async: true

  alias Polyphony.Scene
  alias PolyphonyCore.Visibility
  alias Polyphony.Commands.{ProposeIntroduction, DismissIntroduction}

  alias PolyphonyCore.Events.{
    SceneOpened,
    CharacterEntered,
    IntroductionProposed,
    IntroductionDismissed
  }

  defp evolve(state \\ %Scene{}, events), do: Enum.reduce(events, state, &Scene.apply(&2, &1))

  defp open_scene, do: evolve([%SceneOpened{scene_id: "S1", opened_beat: 0}])

  describe "the aggregate" do
    test "proposing an introduction on an open scene emits IntroductionProposed" do
      state = open_scene()

      assert %IntroductionProposed{
               scene_id: "S1",
               beat: 2,
               name: "Bram",
               reason: "he's owed a debt"
             } =
               Scene.execute(state, %ProposeIntroduction{
                 scene_id: "S1",
                 beat: 2,
                 name: "Bram",
                 reason: "he's owed a debt"
               })
    end

    test "a proposal does NOT make the character a member" do
      state =
        open_scene()
        |> evolve([%IntroductionProposed{scene_id: "S1", beat: 2, name: "Bram"}])

      refute MapSet.member?(state.members, "Bram")
      assert MapSet.member?(state.pending_introductions, "bram")
    end

    test "re-proposing a pending name is a no-op (idempotent, case-insensitive)" do
      state =
        open_scene()
        |> evolve([%IntroductionProposed{scene_id: "S1", beat: 2, name: "Bram"}])

      assert [] =
               Scene.execute(state, %ProposeIntroduction{scene_id: "S1", beat: 3, name: "bram"})
    end

    test "proposing someone already present is refused" do
      state =
        open_scene()
        |> evolve([%CharacterEntered{scene_id: "S1", character_id: "Mira", beat: 1}])

      assert {:error, :already_present} =
               Scene.execute(state, %ProposeIntroduction{scene_id: "S1", beat: 2, name: "Mira"})
    end

    test "entering resolves the pending proposal" do
      state =
        open_scene()
        |> evolve([
          %IntroductionProposed{scene_id: "S1", beat: 2, name: "Bram"},
          %CharacterEntered{scene_id: "S1", character_id: "Bram", beat: 3}
        ])

      assert MapSet.member?(state.members, "Bram")
      refute MapSet.member?(state.pending_introductions, "bram")
    end

    test "dismissing clears a pending proposal; dismissing an unknown name is a no-op" do
      state =
        open_scene()
        |> evolve([%IntroductionProposed{scene_id: "S1", beat: 2, name: "Bram"}])

      assert %IntroductionDismissed{name: "Bram"} =
               Scene.execute(state, %DismissIntroduction{scene_id: "S1", name: "Bram"})

      assert [] = Scene.execute(state, %DismissIntroduction{scene_id: "S1", name: "Nobody"})
    end

    test "proposals are refused on a scene that isn't open" do
      assert {:error, :scene_not_open} =
               Scene.execute(%Scene{}, %ProposeIntroduction{scene_id: "S1", beat: 1, name: "X"})
    end
  end

  describe "visibility (the invariant)" do
    # A membership oracle that would grant everything — proving the deny is by type,
    # not by absence of membership.
    defp always_member, do: fn _s, _c, _b -> true end

    test "an introduction proposal is visible to omniscient" do
      e = %IntroductionProposed{scene_id: "S1", beat: 2, name: "Bram"}
      assert Visibility.visible_to?(e, :omniscient, always_member())
    end

    test "an introduction proposal is invisible to every character — even a present member" do
      e = %IntroductionProposed{scene_id: "S1", beat: 2, name: "Bram"}
      refute Visibility.visible_to?(e, {:character, "Mira"}, always_member())

      d = %IntroductionDismissed{scene_id: "S1", name: "Bram"}
      refute Visibility.visible_to?(d, {:character, "Mira"}, always_member())
    end
  end
end
