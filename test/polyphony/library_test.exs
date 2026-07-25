defmodule Polyphony.LibraryTest do
  @moduledoc """
  §B1: ownership, visibility, and the publish/fork lifecycle end to end.

  Covers persistence + the three transitions: publish freezes a self-contained
  campaign snapshot; instantiate copies a sheet only; fork copies the whole campaign
  (arc included) and re-owns the embedded bible + characters as editable copies.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{Library, Repo}
  alias Polyphony.Library.Snapshot
  alias Polyphony.ReadModels.LibraryEntry
  alias Polyphony.Authoring.{WorldBible, CharacterSheet}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp sheet(name), do: %CharacterSheet{name: name, premise: "#{name}'s premise."}

  describe "ownership + visibility persistence" do
    test "a new entry defaults to private with no share token" do
      row = Library.put(%{owner_id: "u1", kind: "character", payload: sheet("Mira")})
      assert row.visibility == "private"
      assert row.share_token == nil
      assert row.version == 1
      refute row.frozen
      assert %CharacterSheet{name: "Mira"} = Library.payload(row)
    end

    test "an unlisted entry is minted with a share token, resolvable by token" do
      row =
        Library.put(%{
          owner_id: "u1",
          kind: "world_bible",
          visibility: "unlisted",
          payload: %WorldBible{name: "W"}
        })

      assert is_binary(row.share_token)
      assert %LibraryEntry{id: id} = Library.get_by_share_token(row.share_token)
      assert id == row.id
    end

    test "set_visibility to unlisted mints a token; owner's list sees the entry" do
      row = Library.put(%{owner_id: "u1", kind: "character", payload: sheet("Mira")})
      assert {:ok, updated} = Library.set_visibility(row.id, "unlisted")
      assert is_binary(updated.share_token)
      assert [_] = Library.list_for_owner("u1")
    end

    test "list_public returns only public entries of a kind" do
      Library.put(%{
        owner_id: "u1",
        kind: "character",
        visibility: "public",
        payload: sheet("Pub")
      })

      Library.put(%{
        owner_id: "u1",
        kind: "character",
        visibility: "private",
        payload: sheet("Priv")
      })

      Library.put(%{
        owner_id: "u1",
        kind: "world_bible",
        visibility: "public",
        payload: %WorldBible{name: "W"}
      })

      names = "character" |> Library.list_public() |> Enum.map(&Library.payload(&1).name)
      assert names == ["Pub"]
    end

    test "update_payload bumps the version" do
      row = Library.put(%{owner_id: "u1", kind: "character", payload: sheet("Mira")})
      assert {:ok, v2} = Library.update_payload(row.id, sheet("Mira the Bold"))
      assert v2.version == 2
      assert Library.payload(v2).name == "Mira the Bold"
    end
  end

  describe "publish — freeze a self-contained snapshot" do
    test "publishing implies freeze and defaults to public; embeds pinned deps + canon arc" do
      published =
        Library.publish_campaign(%{
          owner_id: "u1",
          campaign_id: "camp",
          published_beat: 3,
          bible: %WorldBible{name: "Aldenmoor"},
          characters: [%{source_id: 1, source_version: 1, sheet: sheet("Mira")}],
          arc: [
            %{status: "canon", statement: "they met", beat: 1},
            %{status: "proposed", statement: "a guess", beat: 2}
          ]
        })

      assert published.frozen
      assert published.visibility == "public"
      assert published.kind == "campaign"

      snap = Library.payload(published)
      assert %Snapshot{bible: %WorldBible{name: "Aldenmoor"}} = snap
      # Canon-only by default: the proposed entry is not in the frozen snapshot.
      assert Enum.map(snap.arc, & &1.statement) == ["they met"]
    end
  end

  describe "instantiate a character — sheet only, re-owned, editable" do
    test "copies the sheet as a new private entry pinned to the source version" do
      source =
        Library.put(%{
          owner_id: "author",
          kind: "character",
          visibility: "public",
          version: 2,
          payload: sheet("Mira")
        })

      copy = Library.instantiate_character(source, "forker")

      assert copy.owner_id == "forker"
      assert copy.visibility == "private"
      refute copy.frozen
      assert copy.derived_from_id == source.id
      assert copy.derived_from_version == 2
      assert %CharacterSheet{name: "Mira"} = Library.payload(copy)

      # Editable after copying: a private-field edit sticks and doesn't touch the source.
      {:ok, edited} = Library.update_payload(copy.id, sheet("Mira Reforged"))
      assert Library.payload(edited).name == "Mira Reforged"
      assert Library.payload(Library.get(source.id)).name == "Mira"
    end
  end

  describe "fork a campaign — whole copy incl. arc, embedded deps re-owned" do
    test "re-owns bible + characters as editable copies and keeps a derived_from pointer" do
      published =
        Library.publish_campaign(%{
          owner_id: "author",
          campaign_id: "camp",
          published_beat: 4,
          bible: %WorldBible{name: "Aldenmoor"},
          characters: [
            %{source_id: 10, source_version: 1, sheet: sheet("Mira")},
            %{source_id: 11, source_version: 1, sheet: sheet("Otto")}
          ],
          arc: [%{status: "canon", statement: "they met", beat: 1}]
        })

      %{campaign: campaign, bible: bible, characters: chars} =
        Library.fork_campaign(published, "forker")

      # The forked campaign is a private, live branch pointing at the new copies.
      assert campaign.owner_id == "forker"
      assert campaign.visibility == "private"
      refute campaign.frozen
      assert campaign.derived_from_id == published.id

      live = Library.payload(campaign)
      assert live.kind == :campaign_ref
      # Arc travels with the fork.
      assert Enum.map(live.arc, & &1.statement) == ["they met"]

      # Embedded bible + characters became new owned, private, editable entries.
      assert bible.owner_id == "forker" and bible.visibility == "private"
      assert length(chars) == 2

      assert Enum.all?(
               chars,
               &(&1.owner_id == "forker" and &1.visibility == "private" and not &1.frozen)
             )

      # derived_from pins each character to its source in the published snapshot.
      assert Enum.map(chars, & &1.derived_from_id) == [10, 11]
      assert live.character_entry_ids == Enum.map(chars, & &1.id)
    end
  end
end
