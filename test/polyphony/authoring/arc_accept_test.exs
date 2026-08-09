defmodule Polyphony.Authoring.ArcAcceptTest do
  @moduledoc """
  Accepting an arc proposal that names somebody who doesn't exist yet (STR-62): the
  walk-on is minted at accept, and the relationship ends up pointing at an id.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{Campaigns, Library, Repo}
  alias Polyphony.Owner
  alias Polyphony.Authoring.{ArcAccept, ArcEntry, CharacterSheet, Stub}
  alias Polyphony.ReadModels.ArcEntry, as: ArcRM

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    owner = Owner.of(PolyphonyWeb.ConnCase.user_fixture())

    wren =
      Library.put(%{
        owner: owner,
        kind: "character",
        payload: %CharacterSheet{name: "Wren", status: :full, world_bible_id: 7}
      })

    camp =
      Library.put(%{
        owner: owner,
        kind: "campaign",
        payload: %{kind: :campaign, name: "The Salt Line", character_ids: [wren.id], scenes: []}
      })

    %{owner: owner, wren: wren, camp: camp}
  end

  defp relationship(subject_id, target, opts \\ []) do
    ArcRM.put(
      Repo,
      %ArcEntry{
        kind: :discovery,
        sheet_field: "relationships",
        statement: "The only person on the quay she'd trust with a key.",
        target: target,
        target_id: opts[:target_id],
        operation: :add,
        author: "allen"
      },
      subject_id
    )
  end

  test "an unknown name is minted as a walk-on and the row points at its id", ctx do
    row = relationship(ctx.wren.id, "Marek Holt")

    ArcAccept.accept(row.id, ctx.owner)

    assert %{status: "canon", target_id: target_id} = ArcRM.get(Repo, row.id)
    assert target_id not in [nil, ""]

    stub = Library.get(target_id)
    sheet = Library.payload(stub)

    assert %CharacterSheet{name: "Marek Holt", tier: :incidental} = sheet
    assert Stub.stub?(sheet)
    # The world of the person who named them, so they already belong to the setting.
    assert sheet.world_bible_id == 7
    # And the regard that named them, pointing back at her by id.
    assert [%{target: "Wren", target_id: wren_id}] = sheet.relationships
    assert wren_id == to_string(ctx.wren.id)
  end

  test "the walk-on joins the campaign that named them", ctx do
    row = relationship(ctx.wren.id, "Marek Holt")
    ArcAccept.accept(row.id, ctx.owner)

    target_id = ArcRM.get(Repo, row.id).target_id
    assert Campaigns.of_character(ctx.owner, target_id).id == ctx.camp.id
  end

  test "a name that is already somebody resolves to them rather than minting a second", ctx do
    marek =
      Library.put(%{
        owner: ctx.owner,
        kind: "character",
        payload: %CharacterSheet{name: "Marek Holt", status: :full}
      })

    row = relationship(ctx.wren.id, "marek holt")
    ArcAccept.accept(row.id, ctx.owner)

    assert ArcRM.get(Repo, row.id).target_id == to_string(marek.id)

    assert Library.list_for_owner(ctx.owner)
           |> Enum.count(&(&1.kind == "character")) == 2
  end

  test "refusing a proposal mints nobody — a person is a thing accepting does", ctx do
    row = relationship(ctx.wren.id, "Marek Holt")
    ArcRM.reject(Repo, row.id)

    refute Enum.any?(Library.list_for_owner(ctx.owner), fn e ->
             match?(%CharacterSheet{name: "Marek Holt"}, Library.payload(e))
           end)
  end

  test "a relationship that already names an id is left alone", ctx do
    other =
      Library.put(%{
        owner: ctx.owner,
        kind: "character",
        payload: %CharacterSheet{name: "Ilias", status: :full}
      })

    row = relationship(ctx.wren.id, "Ilias", target_id: to_string(other.id))
    ArcAccept.accept(row.id, ctx.owner)

    assert ArcRM.get(Repo, row.id).target_id == to_string(other.id)
    assert Library.list_for_owner(ctx.owner) |> Enum.count(&(&1.kind == "character")) == 2
  end

  test "accept_all settles every relationship it promotes", ctx do
    relationship(ctx.wren.id, "Marek Holt")
    relationship(ctx.wren.id, "Sable Quist")
    ArcRM.put(Repo, %ArcEntry{kind: :discovery, statement: "She carries a key."}, ctx.wren.id)

    assert 3 = ArcAccept.accept_all(ctx.wren.id, "character", ctx.owner)

    assert Repo
           |> ArcRM.list_canon(ctx.wren.id)
           |> Enum.filter(&(&1.sheet_field == "relationships"))
           |> Enum.all?(&(&1.target_id not in [nil, ""]))
  end
end
