defmodule Polyphony.Accounts.RolesTest do
  @moduledoc """
  §B2 planned addition #4: the pure role-authorization rules. Tested hardest are the
  two invariants — the superadmin is un-demotable, and `:superadmin` is never handed
  out by promotion — so there is always exactly one, the first sign-up.
  """
  use ExUnit.Case, async: true

  alias Polyphony.Accounts.Roles

  describe "the superadmin is untouchable" do
    test "no actor can change a superadmin's role — not even a superadmin (self-demotion)" do
      for actor <- [:user, :admin, :superadmin], new <- [:user, :admin, :superadmin] do
        refute Roles.can_change_role?(actor, :superadmin, new)
      end
    end
  end

  describe ":superadmin is never assignable" do
    test "no promotion path produces a second superadmin" do
      for actor <- [:user, :admin, :superadmin], target <- [:user, :admin] do
        refute Roles.can_change_role?(actor, target, :superadmin)
      end
    end
  end

  describe "promotion to admin" do
    test "an admin or the superadmin may promote a user; a user may not" do
      assert Roles.can_change_role?(:admin, :user, :admin)
      assert Roles.can_change_role?(:superadmin, :user, :admin)
      refute Roles.can_change_role?(:user, :user, :admin)
    end
  end

  describe "demotion of an admin" do
    test "only the superadmin may demote an admin to user" do
      assert Roles.can_change_role?(:superadmin, :admin, :user)
      # A regular admin cannot demote peers.
      refute Roles.can_change_role?(:admin, :admin, :user)
      refute Roles.can_change_role?(:user, :admin, :user)
    end
  end

  test "no-op and unknown transitions are denied (default-deny)" do
    refute Roles.can_change_role?(:admin, :user, :user)
    refute Roles.can_change_role?(:superadmin, :admin, :admin)
  end

  test "admin?/1 gates admin-or-above" do
    assert Roles.admin?(:admin)
    assert Roles.admin?(:superadmin)
    refute Roles.admin?(:user)
  end
end
