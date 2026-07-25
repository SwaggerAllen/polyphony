defmodule Polyphony.LibraryOwnerTest do
  @moduledoc """
  §P2/§P8: the `Library` speaks `Owner`. A bare id is a user owner (v1 default), an
  org-typed owner is stored + queried distinctly, and access-as-owner for an org
  entry is default-denied until the (deliberately deferred) org permission layer.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{Library, Owner, Repo}
  alias Polyphony.Library.Access

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  test "a bare id and an explicit user owner address the same library" do
    Library.put(%{owner_id: "u1", kind: "character", payload: %{n: 1}})
    Library.put(%{owner: Owner.user("u1"), kind: "world_bible", payload: %{n: 2}})

    assert length(Library.list_for_owner("u1")) == 2
    assert length(Library.list_for_owner(Owner.user("u1"))) == 2
    # The stored row records the owner type explicitly.
    [entry | _] = Library.list_for_owner("u1")
    assert entry.owner_type == "user"
  end

  test "an org owner is a distinct library from a same-id user owner" do
    org = %Owner{type: :org, id: "1"}
    Library.put(%{owner: Owner.user("1"), kind: "character", payload: %{who: "user"}})
    Library.put(%{owner: org, kind: "character", payload: %{who: "org"}})

    assert [%{owner_type: "user"}] = Library.list_for_owner(Owner.user("1"))
    assert [%{owner_type: "org"}] = Library.list_for_owner(org)
  end

  test "access-as-owner: a user owns their entry; org entries default-deny a bare actor" do
    user_entry = Library.put(%{owner: Owner.user("42"), kind: "character", payload: %{}})

    org_entry =
      Library.put(%{owner: %Owner{type: :org, id: "9"}, kind: "character", payload: %{}})

    assert Access.can_write?(user_entry, %{actor_id: "42", token: nil})
    refute Access.can_write?(user_entry, %{actor_id: "99", token: nil})

    # The org's id matches the actor id, but org ownership isn't grantable to a bare
    # actor — it resolves through a permission layer that is a later addition (§P8).
    refute Access.can_write?(org_entry, %{actor_id: "9", token: nil})
  end
end
