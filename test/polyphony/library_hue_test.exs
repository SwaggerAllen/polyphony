defmodule Polyphony.LibraryHueTest do
  @moduledoc """
  A character's voice colour is assigned once, at creation, and never moves.

  The kit's rule is that a character is the same hue in the transcript, the status
  strip, the cast list, the picker and their own sheet. Deriving the colour from
  position in a cast satisfies that only until somebody is removed — then everyone
  after them changes colour, *including in transcripts they already appear in*,
  which is the one place a colour is supposed to be a stable identity cue.

  So the hue is a stored field, minted at `Library.put/2` — the single door every
  character comes through. These tests pin the property that made it worth storing:
  it survives everything that happens to the cast afterwards.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{Library, Repo}
  alias Polyphony.Owner
  alias Polyphony.Authoring.CharacterSheet

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp owner, do: Owner.coerce(System.unique_integer([:positive]))

  defp character(owner, name) do
    Library.put(%{
      owner: owner,
      kind: "character",
      payload: %CharacterSheet{name: name, status: :full}
    })
  end

  defp hue(entry), do: entry.id |> Library.get() |> Library.payload() |> Map.get(:hue)

  test "every character is given one at creation" do
    o = owner()

    for name <- ~w(Wren Ilias Corrigan) do
      assert hue(character(o, name)) in 1..CharacterSheet.hue_count()
    end
  end

  test "a fresh cast spreads across the palette rather than clustering" do
    o = owner()
    hues = for n <- 1..4, do: hue(character(o, "c#{n}"))

    assert hues == Enum.uniq(hues)
  end

  test "removing someone from the middle doesn't recolour anyone" do
    # The failure mode of order-derived colours, made concrete.
    o = owner()
    [a, b, c] = for n <- ~w(a b c), do: character(o, n)
    before = Enum.map([a, b, c], &hue/1)

    Library.soft_delete(b.id)

    assert Enum.map([a, c], &hue/1) == [Enum.at(before, 0), Enum.at(before, 2)]
  end

  test "an edit to the sheet leaves the hue alone" do
    o = owner()
    wren = character(o, "Wren")
    original = hue(wren)

    {:ok, _} =
      Library.update_payload(wren.id, %{
        Library.payload(Library.get(wren.id))
        | name: "Wren Ashgrove"
      })

    assert hue(wren) == original
  end

  test "a hue an author has already chosen is never overwritten" do
    # The reason it's a stored field rather than a derivation: it leaves room for
    # someone to pick their own, and creation must not stomp that.
    o = owner()

    entry =
      Library.put(%{
        owner: o,
        kind: "character",
        payload: %CharacterSheet{name: "Wren", status: :full, hue: 7}
      })

    assert hue(entry) == 7
  end

  test "only characters get one — a world or a campaign is not a voice" do
    o = owner()

    entry =
      Library.put(%{
        owner: o,
        kind: "campaign",
        payload: %{kind: :campaign, name: "Camp", character_ids: [], scenes: []}
      })

    refute Map.has_key?(Library.payload(entry), :hue)
  end
end
