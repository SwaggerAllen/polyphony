defmodule Polyphony.OwnerTest do
  @moduledoc """
  §P2/§P8: owner as an indirection. Today every owner is a user, but ownership is a
  `{type, id}` value that can become polymorphic without re-encoding ids.
  """
  use ExUnit.Case, async: true

  alias Polyphony.Owner
  alias Polyphony.Accounts.User

  test "user/1, of/1, and coerce/1 all normalize to a user owner" do
    assert Owner.user(7) == %Owner{type: :user, id: "7"}
    assert Owner.of(%User{id: 7}) == Owner.user(7)
    # coerce accepts an owner, a user, or a bare id (the v1 default).
    assert Owner.coerce(Owner.user("u1")) == Owner.user("u1")
    assert Owner.coerce(%User{id: 3}) == Owner.user(3)
    assert Owner.coerce("u1") == Owner.user("u1")
    assert Owner.coerce(9) == Owner.user(9)
  end

  test "key/1 round-trips through parse/1" do
    owner = Owner.user("42")
    assert Owner.key(owner) == "user:42"
    assert Owner.parse("user:42") == owner
    # A bare (typeless) key parses as a user, the default.
    assert Owner.parse("bareid") == Owner.user("bareid")
  end

  test "same?/2 compares type and id" do
    assert Owner.same?(Owner.user("1"), Owner.user("1"))
    refute Owner.same?(Owner.user("1"), Owner.user("2"))
    refute Owner.same?(Owner.user("1"), %Owner{type: :org, id: "1"})
  end

  test "user?/1 distinguishes user from org owners" do
    assert Owner.user?(Owner.user("1"))
    refute Owner.user?(%Owner{type: :org, id: "1"})
  end
end
