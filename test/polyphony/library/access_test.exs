defmodule Polyphony.Library.AccessTest do
  @moduledoc """
  §B1: the pure access predicate. Access is default-deny and a property of the data
  (visibility + ownership + token) — the same posture the fiction visibility layer
  takes. Tested hardest: a private entry must never read to a stranger, and no
  anonymous viewer may ever write.
  """
  use ExUnit.Case, async: true

  alias Polyphony.Library.Access
  alias Polyphony.ReadModels.LibraryEntry

  defp entry(visibility, opts \\ []) do
    %LibraryEntry{
      owner_id: Keyword.get(opts, :owner_id, "owner"),
      visibility: to_string(visibility),
      share_token: Keyword.get(opts, :share_token)
    }
  end

  defp viewer(actor_id, token \\ nil), do: %{actor_id: actor_id, token: token}

  describe "public" do
    test "readable by anyone, signed out included; not writable by non-owners" do
      e = entry(:public)
      assert Access.can_read?(e, Access.anonymous())
      assert Access.can_read?(e, viewer("stranger"))
      refute Access.can_write?(e, Access.anonymous())
      refute Access.can_write?(e, viewer("stranger"))
    end
  end

  describe "unlisted" do
    test "readable only with the matching token" do
      e = entry(:unlisted, share_token: "secret-tok")
      assert Access.can_read?(e, viewer("stranger", "secret-tok"))
      refute Access.can_read?(e, viewer("stranger", "wrong"))
      refute Access.can_read?(e, viewer("stranger"))
      refute Access.can_read?(e, Access.anonymous())
    end

    test "a nil token on either side never matches" do
      refute Access.can_read?(entry(:unlisted, share_token: nil), viewer("x", "anything"))
      refute Access.can_read?(entry(:unlisted, share_token: "t"), viewer("x", nil))
    end
  end

  describe "private" do
    test "readable only by the owner; a stranger and anonymous are denied" do
      e = entry(:private, owner_id: "owner")
      assert Access.can_read?(e, viewer("owner"))
      refute Access.can_read?(e, viewer("stranger"))
      refute Access.can_read?(e, Access.anonymous())
      # A share token does not open a private entry.
      refute Access.can_read?(entry(:private, share_token: "t"), viewer("stranger", "t"))
    end
  end

  describe "writes require auth + ownership" do
    test "only the authenticated owner may write, at any visibility" do
      for vis <- [:private, :unlisted, :public] do
        e = entry(vis, owner_id: "owner", share_token: "t")
        assert Access.can_write?(e, viewer("owner"))
        refute Access.can_write?(e, viewer("stranger"))
        refute Access.can_write?(e, Access.anonymous())
      end
    end

    test "a nil actor never counts as owner even if owner_id is somehow nil" do
      refute Access.can_write?(%LibraryEntry{owner_id: nil, visibility: "private"}, viewer(nil))
    end
  end

  test "an unrecognized visibility denies non-owner reads (default-deny)" do
    e = %LibraryEntry{owner_id: "owner", visibility: "bogus"}
    refute Access.can_read?(e, viewer("stranger"))
    assert Access.can_read?(e, viewer("owner"))
  end
end
