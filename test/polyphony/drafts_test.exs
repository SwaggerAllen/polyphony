defmodule Polyphony.DraftsTest do
  @moduledoc """
  Pending drafts (§A2): the generate-then-confirm state. A draft is workflow state,
  never fiction — it stays off the event log, so it can't reach any projection until
  accepted, at which point it becomes an ordinary committed packet.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{App, Repo, Context, Drafts, Suggest}
  alias PolyphonyCore.Packets
  alias Polyphony.LLM.Mock
  alias Polyphony.Authoring.CharacterSheet
  alias PolyphonyCore.Commands.{OpenScene, EnterCharacter}
  alias PolyphonyCore.Events.ThoughtOccurred
  alias PolyphonyCore.TurnPacket
  alias PolyphonyCore.TurnPacket.{Move, SelfState}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp stored(s), do: App |> Commanded.EventStore.stream_forward(s) |> Enum.map(& &1.data)
  defp canonical(s), do: s |> stored() |> Packets.canonical()

  defp thought_chars(s),
    do: for(%ThoughtOccurred{character_id: c} <- canonical(s), do: c) |> Enum.uniq()

  defp packet(mark) do
    %TurnPacket{
      moves: [
        %Move{seq: 1, type: :thought, content: "#{mark}-thought"},
        %Move{seq: 2, type: :speech, content: "#{mark}-speech"}
      ],
      self_state: %SelfState{mood_felt: "m", demeanor: "d"}
    }
  end

  defp open_scene(members) do
    scene = "draft-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})
    for m <- members, do: App.dispatch(%EnterCharacter{scene_id: scene, character_id: m, beat: 1})
    scene
  end

  describe "the store" do
    test "a draft round-trips its packet losslessly and lists as open" do
      scene = open_scene(["mira"])
      row = Drafts.draft(scene, "mira", 2, packet("hi"), repo: Repo, source: "assisted")

      assert %{status: "pending", source: "assisted", edited: false} = row

      assert %TurnPacket{moves: [%Move{type: :thought}, %Move{type: :speech}]} =
               Drafts.packet(row)

      assert [%{id: id}] = Drafts.list_open(scene, repo: Repo)
      assert id == row.id
    end

    test "editing replaces the packet and marks it edited" do
      scene = open_scene(["mira"])
      row = Drafts.draft(scene, "mira", 2, packet("first"), repo: Repo)

      {:ok, edited} = Drafts.edit(row.id, packet("second"), repo: Repo)
      assert edited.edited == true
      assert Drafts.packet(edited) |> hd_content() == "second-thought"
    end

    test "discard resolves the draft without committing" do
      scene = open_scene(["mira"])
      row = Drafts.draft(scene, "mira", 2, packet("x"), repo: Repo)

      {:ok, _} = Drafts.discard(row.id, repo: Repo)
      assert Drafts.list_open(scene, repo: Repo) == []
      # Nothing reached the fiction log.
      assert thought_chars(scene) == []
    end

    test "broadcasts draft.ready to the omniscient viewer" do
      scene = open_scene(["mira"])
      Phoenix.PubSub.subscribe(Polyphony.PubSub, Polyphony.Broadcast.topic(scene, :omniscient))

      Drafts.draft(scene, "mira", 2, packet("x"), repo: Repo)

      assert_receive {:polyphony_event, %{type: "draft.ready", character_id: "mira"}}
    end
  end

  describe "the off-the-log guarantee (§A2)" do
    test "a pending draft is invisible on the fiction log; accepting commits it" do
      scene = open_scene(["mira"])
      row = Drafts.draft(scene, "mira", 2, packet("secret"), repo: Repo)

      # While pending it is NOT a fact — nothing on the canonical stream.
      assert thought_chars(scene) == []
      refute Enum.any?(canonical(scene), &match?(%ThoughtOccurred{content: "secret-thought"}, &1))

      assert {:ok, %{packet_id: _}} = Drafts.accept(row.id, repo: Repo)

      # Now it's a committed fact.
      assert "mira" in thought_chars(scene)
      assert Enum.any?(canonical(scene), &match?(%ThoughtOccurred{content: "secret-thought"}, &1))
    end

    test "an edited draft commits with the edited marker" do
      scene = open_scene(["mira"])
      row = Drafts.draft(scene, "mira", 2, packet("draft"), repo: Repo)
      {:ok, _} = Drafts.edit(row.id, packet("polished"), repo: Repo)
      {:ok, _} = Drafts.accept(row.id, repo: Repo)

      committed =
        Enum.find(canonical(scene), &match?(%ThoughtOccurred{content: "polished-thought"}, &1))

      assert committed.edited == true
    end
  end

  # Assisted mode *in the beat walk* (generate → draft → accept/discard resumes the
  # loop) is exercised end-to-end on the Oban path — see `Jobs.ObanControlTest`.

  test "suggestion variants are the same pending mechanism (source: suggestion)" do
    scene = open_scene(["mira"])
    sheet = %CharacterSheet{name: "mira", premise: "mira here.", voice: "plain"}

    ctx =
      Context.materialize(scene_id: scene, character_id: "mira", sheet: sheet, premise: "A room.")

    {:ok, variants} = Suggest.variants(context: ctx, provider: Mock, count: 2)

    drafts =
      Enum.map(variants, &Drafts.draft(scene, "mira", 2, &1, repo: Repo, source: "suggestion"))

    assert length(Drafts.list_open(scene, repo: Repo)) == 2
    assert Enum.all?(drafts, &(&1.source == "suggestion"))

    # Accept one → it commits; the rest stay pending for the user to discard.
    {:ok, _} = Drafts.accept(hd(drafts).id, repo: Repo)
    assert "mira" in thought_chars(scene)
    assert length(Drafts.list_open(scene, repo: Repo)) == 1
  end

  defp hd_content(%TurnPacket{moves: [%Move{content: c} | _]}), do: c
end
