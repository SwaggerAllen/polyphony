defmodule Polyphony.EditTest do
  @moduledoc """
  Editing committed turns (§A4): a correction supersedes the original. `:valid`
  edits in place; `:invalid` forks, preserving the original timeline and applying
  the edit on a branch. Runs end-to-end through Commanded.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{App, Edit, Packets, MembershipSet, Visibility}
  alias Polyphony.TurnPacket
  alias Polyphony.TurnPacket.{Move, SelfState}
  alias Polyphony.Commands.{OpenScene, EnterCharacter, CommitPacket}
  alias Polyphony.Events.{ThoughtOccurred, SpeechUttered, PacketSuperseded}

  defp new_scene, do: "edit-" <> Integer.to_string(System.unique_integer([:positive]))
  defp raw(scene), do: App |> Commanded.EventStore.stream_forward(scene) |> Enum.map(& &1.data)
  defp canonical(scene), do: scene |> raw() |> Packets.canonical()
  defp contents(events), do: events |> Enum.map(&Map.get(&1, :content)) |> Enum.reject(&is_nil/1)

  defp superseded_markers(scene),
    do: for(%PacketSuperseded{packet_id: id} <- raw(scene), do: id)

  defp packet(mark) do
    %TurnPacket{
      moves: [
        %Move{seq: 1, type: :thought, content: "#{mark}-thought"},
        %Move{seq: 2, type: :speech, content: "#{mark}-speech"}
      ],
      self_state: %SelfState{mood_felt: "m", demeanor: "d"}
    }
  end

  defp commit(scene, char, beat, mark) do
    :ok =
      App.dispatch(%CommitPacket{
        scene_id: scene,
        character_id: char,
        beat: beat,
        packet_id: "#{scene}-#{beat}-#{char}",
        packet: packet(mark)
      })
  end

  # alice → bram → cara committed at beat 2.
  defp scene_with_beat do
    scene = new_scene()
    :ok = App.dispatch(%OpenScene{scene_id: scene, campaign_id: "camp-1", opened_beat: 0})

    for c <- ["alice", "bram", "cara"],
        do: App.dispatch(%EnterCharacter{scene_id: scene, character_id: c, beat: 1})

    commit(scene, "alice", 2, "alice")
    commit(scene, "bram", 2, "bram")
    commit(scene, "cara", 2, "cara")
    scene
  end

  describe "a valid edit (downstream still valid)" do
    test "supersedes only the edited packet and commits the correction in place" do
      scene = scene_with_beat()

      assert {:ok, %{forked: false, scene_id: ^scene}} =
               Edit.edit(scene, 2, "bram", packet("fixed"), :valid)

      cs = scene |> canonical() |> contents()
      assert "fixed-thought" in cs
      refute "bram-thought" in cs
      # The user asserted downstream is fine, so alice AND cara are untouched.
      assert "alice-thought" in cs
      assert "cara-thought" in cs

      # Only bram's original packet was superseded — not the in-beat tail.
      assert superseded_markers(scene) == ["#{scene}-2-bram"]
    end

    test "the corrected moves carry the edited marker" do
      scene = scene_with_beat()
      {:ok, _} = Edit.edit(scene, 2, "bram", packet("fixed"), :valid)

      corrected =
        Enum.find(canonical(scene), &match?(%ThoughtOccurred{content: "fixed-thought"}, &1))

      assert corrected.edited == true
    end

    test "works on an earlier, non-latest beat without forking" do
      scene = new_scene()
      :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})
      :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: "alice", beat: 1})
      commit(scene, "alice", 2, "old")
      commit(scene, "alice", 3, "later")

      assert {:ok, %{forked: false}} = Edit.edit(scene, 2, "alice", packet("fixed"), :valid)

      cs = scene |> canonical() |> contents()
      assert "fixed-thought" in cs
      assert "later-thought" in cs, "the untouched later beat survives a valid edit"
    end

    test "editing a private thought stays private" do
      scene = scene_with_beat()
      {:ok, _} = Edit.edit(scene, 2, "bram", packet("fixed"), :valid)

      events = canonical(scene)
      member_at? = events |> MembershipSet.from_events() |> MembershipSet.member_at_fun()
      cara_view = Visibility.project(events, {:character, "cara"}, member_at?)

      # Cara sees the corrected speech but never bram's corrected interior.
      assert Enum.any?(cara_view, &match?(%SpeechUttered{content: "fixed-speech"}, &1))
      refute Enum.any?(cara_view, &match?(%ThoughtOccurred{content: "fixed-thought"}, &1))
    end
  end

  describe "an invalid edit (downstream invalid)" do
    test "forks, preserves the original timeline, and applies the edit on the branch" do
      scene = scene_with_beat()

      assert {:ok, %{forked: true, scene_id: branch, parent_scene_id: ^scene}} =
               Edit.edit(scene, 2, "bram", packet("redo"), :invalid)

      # The original is untouched — no supersession, nothing regenerated.
      assert superseded_markers(scene) == []
      original = scene |> canonical() |> contents()
      assert "bram-thought" in original
      assert "cara-thought" in original

      # The branch carries the edit; the stale in-beat tail (cara) is discarded.
      branched = branch |> canonical() |> contents()
      assert "alice-thought" in branched
      assert "redo-thought" in branched
      refute "bram-thought" in branched
      refute "cara-thought" in branched
    end

    test "the branch is a live, playable scene" do
      scene = scene_with_beat()
      {:ok, %{scene_id: branch}} = Edit.edit(scene, 2, "bram", packet("redo"), :invalid)

      # Continue the story forward on the branch — a fresh beat commits normally.
      commit(branch, "alice", 3, "onward")
      assert "onward-thought" in (branch |> canonical() |> contents())
    end
  end

  test "editing a character with no packet in the beat is not found" do
    scene = scene_with_beat()
    assert {:error, :packet_not_found} = Edit.edit(scene, 2, "nobody", packet("x"), :valid)
  end
end
