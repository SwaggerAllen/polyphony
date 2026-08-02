defmodule Polyphony.SceneResetTest do
  @moduledoc """
  The clean-slate wipe removes play and keeps authored work.

  The distinction is the whole point of §5.2's reset decision: scenes carry the old
  name-keyed identity and have to go, but characters, worlds and campaigns are work
  someone did and must survive. A wipe that took the library with it would be a data
  loss dressed up as a migration.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{Library, Owner, Repo, SceneReset}
  alias Polyphony.Authoring.{ArcEntry, CharacterSheet}
  alias Polyphony.ReadModels.ArcEntry, as: ArcRM

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp owner, do: Owner.coerce(1)

  defp character(name) do
    Library.put(%{
      owner: owner(),
      kind: "character",
      payload: %CharacterSheet{name: name, status: :full}
    })
  end

  defp campaign(scenes) do
    Library.put(%{
      owner: owner(),
      kind: "campaign",
      payload: %{kind: :campaign, name: "Camp", character_ids: [], bible_id: nil, scenes: scenes}
    })
  end

  test "scene-derived rows go, library entries stay" do
    wren = character("Wren")
    camp = campaign(["sc-1", "sc-2"])

    ArcRM.put(
      Repo,
      %ArcEntry{kind: :discovery, statement: "She stopped signing.", status: :proposed},
      to_string(wren.id)
    )

    Polyphony.ReadModels.Membership.enter(Repo, "sc-1", wren.id, 1)

    result = reset()

    # Play is gone.
    assert ArcRM.list_proposed(Repo, to_string(wren.id)) == []
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM scene_memberships")
    assert result.rows["arc_entries"] == 1
    assert result.rows["scene_memberships"] == 1

    # Authored work is not.
    assert %CharacterSheet{name: "Wren"} = wren.id |> Library.get() |> Library.payload()
    assert Library.get(camp.id)
  end

  test "a campaign stops linking to streams that no longer exist" do
    camp = campaign(["sc-1", "sc-2"])

    result = reset()

    assert result.campaigns == 1
    assert Library.payload(Library.get(camp.id))[:scenes] == []
  end

  test "a campaign that never opened a scene isn't counted as changed" do
    campaign([])

    assert reset().campaigns == 0
  end

  test "skipping the streams is reported, not silently implied" do
    # The suite always skips them (see `reset/0`), and a run that didn't touch the
    # event store must say so rather than let a caller read the summary as a full wipe.
    assert reset().streams == :skipped
  end

  # The suite configures a persistent event store for its own end-to-end test, so this
  # exercises the read-model half only — resetting the streams here would pull the rug
  # from under an unrelated test. The stream reset is a single `Initializer.reset!/3`
  # call against the same config `mix event_store.init` uses.
  defp reset, do: SceneReset.run!(streams: false)
end
