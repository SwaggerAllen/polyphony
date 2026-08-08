defmodule Polyphony.PermissionsTest do
  @moduledoc """
  §B1: the one predicate that answers *may this actor see or change this entry*.

  These rules were written twice. `Polyphony.Library.Access` held this set — pure,
  default-deny, and the only implementation that checked a share token — and **nothing
  in `lib/` ever called it**, while the two gates that were called both treated
  `unlisted` as a synonym for `public`. The rules survive here because they were the
  right ones; what changed is that the module holding them is now the one the app asks.

  Tested hardest: a private entry must never read to a stranger, and an unlisted one
  must never read to somebody who doesn't hold the link. That second is the rule the
  duplication cost us — see `PolyphonyWeb.BrowseAccessLiveTest` for the leak itself.
  """
  use ExUnit.Case, async: true

  alias Polyphony.Owner
  alias Polyphony.Permissions
  alias Polyphony.ReadModels.LibraryEntry

  defp entry(visibility, opts \\ []) do
    %LibraryEntry{
      owner_type: Keyword.get(opts, :owner_type, "user"),
      owner_id: Keyword.get(opts, :owner_id, "owner"),
      visibility: to_string(visibility),
      share_token: Keyword.get(opts, :share_token),
      frozen: Keyword.get(opts, :frozen, false)
    }
  end

  describe "public" do
    test "readable by anyone, signed out included; not editable by non-owners" do
      e = entry(:public)

      assert Permissions.can_view?(e, nil)
      assert Permissions.can_view?(e, "stranger")
      refute Permissions.can_edit?(e, nil)
      refute Permissions.can_edit?(e, "stranger")
    end
  end

  describe "unlisted" do
    test "readable only with the matching token" do
      e = entry(:unlisted, share_token: "secret-tok")

      assert Permissions.can_view?(e, "stranger", token: "secret-tok")
      refute Permissions.can_view?(e, "stranger", token: "wrong")
      refute Permissions.can_view?(e, "stranger")
      refute Permissions.can_view?(e, nil)
    end

    test "a nil token on either side never matches" do
      refute Permissions.can_view?(entry(:unlisted, share_token: nil), "x", token: "anything")
      refute Permissions.can_view?(entry(:unlisted, share_token: "t"), "x", token: nil)
    end

    test "its owner reads it without holding the link" do
      # They made it; being sent your own share URL to open your own story would be
      # absurd. This is also why `can_view?` can't just be "public or holds the token".
      assert Permissions.can_view?(entry(:unlisted, share_token: "t"), "owner")
    end
  end

  describe "private" do
    test "readable only by the owner; a stranger and anonymous are denied" do
      e = entry(:private)

      assert Permissions.can_view?(e, "owner")
      refute Permissions.can_view?(e, "stranger")
      refute Permissions.can_view?(e, nil)
    end

    test "a share token does not open a private entry" do
      # Visibility is what grants; the token only proves you hold the link that an
      # unlisted entry's grant is made of. A token that opened a private entry would
      # make revoking a share by going private do nothing.
      refute Permissions.can_view?(entry(:private, share_token: "t"), "stranger", token: "t")
    end
  end

  describe "frozen" do
    test "stops writing, not reading" do
      # A published snapshot refuses every edit, its author's included. Reading used to
      # fall through to the edit check, which meant an author could not open their own
      # unlisted publication — the one entry they most certainly may read.
      e = entry(:unlisted, frozen: true, share_token: "t")

      refute Permissions.can_edit?(e, "owner")
      assert Permissions.can_view?(e, "owner")
      assert Permissions.can_view?(e, "stranger", token: "t")
    end
  end

  describe "taken down" do
    test "a hidden entry reads and edits to nobody, its owner included" do
      # §B3: a take-down takes everything. The owner is told by email; they are not
      # told by still being able to open it.
      e = entry(:public, hidden_at: nil) |> Map.put(:hidden_at, ~N[2026-01-01 00:00:00.000000])

      refute Permissions.can_view?(e, "owner")
      refute Permissions.can_view?(e, "stranger")
      refute Permissions.can_edit?(e, "owner")
    end
  end

  describe "ownership" do
    test "an org entry is not owned by a bare actor id" do
      # A bare id coerces to a *user* owner, so it can never match an org-owned row.
      # Org membership resolves through a permission layer that is a deliberate later
      # addition (§P8), and this default-denies rather than guessing at it.
      org = entry(:private, owner_type: "org", owner_id: "9")

      refute Permissions.can_view?(org, "9")
      refute Permissions.can_edit?(org, "9")
      assert Permissions.owner?(org, %Owner{type: :org, id: "9"})
    end

    test "a nil actor never counts as owner, even against a nil owner_id" do
      refute Permissions.can_edit?(%LibraryEntry{owner_id: nil, visibility: "private"}, nil)
    end
  end

  test "an unrecognized visibility denies non-owner reads (default-deny)" do
    e = entry(:bogus)

    refute Permissions.can_view?(e, "stranger")
    assert Permissions.can_view?(e, "owner")
  end

  test "nil is never viewable or editable" do
    # A missing entry and a moderated one arrive here the same way, and the caller
    # reports both as *not found* — saying which would tell a stranger something true
    # about somebody else's account.
    refute Permissions.can_view?(nil, "anyone")
    refute Permissions.can_edit?(nil, "anyone")
  end
end
