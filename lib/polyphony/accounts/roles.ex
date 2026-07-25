defmodule Polyphony.Accounts.Roles do
  @moduledoc """
  The **pure** role-authorization rules (§B2, planned addition #4).

  Three roles, strictly ordered: `:user` < `:admin` < `:superadmin`. The first
  account to sign up becomes the sole `:superadmin` (`Polyphony.Accounts.register/2`);
  everyone else starts a `:user`. The invariants tested hardest here:

    * **The superadmin is un-demotable** — no actor, not even themselves, can change a
      superadmin's role. There is exactly one, minted at first sign-up.
    * **`:superadmin` is never *assignable*** — it is only ever the first-user grant,
      so no promotion path can create a second one.
    * **Promotion to `:admin`** — any admin or the superadmin may promote a `:user`.
    * **Demotion of an `:admin`** — only the superadmin may demote an admin to `:user`.

  Default-deny: anything not explicitly permitted is refused.
  """

  @roles [:user, :admin, :superadmin]

  @doc "The role vocabulary, least to most privileged."
  @spec roles() :: [atom()]
  def roles, do: @roles

  @doc "Is `role` one the system recognizes?"
  @spec role?(term()) :: boolean()
  def role?(role), do: role in @roles

  @doc """
  May an actor with `actor_role` change a target currently `target_role` **to**
  `new_role`? Pure; default-deny.
  """
  @spec can_change_role?(atom(), atom(), atom()) :: boolean()
  def can_change_role?(actor_role, target_role, new_role)

  # The superadmin is untouchable — protects the single un-demotable owner.
  def can_change_role?(_actor, :superadmin, _new), do: false

  # Superadmin is never handed out by promotion; it is the first-user grant only.
  def can_change_role?(_actor, _target, :superadmin), do: false

  # Promote a plain user to admin: any admin or the superadmin may.
  def can_change_role?(actor, :user, :admin), do: actor in [:admin, :superadmin]

  # Demote an admin back to user: superadmin only.
  def can_change_role?(:superadmin, :admin, :user), do: true

  # Everything else (no-ops, unknown roles, admins demoting admins) is denied.
  def can_change_role?(_actor, _target, _new), do: false

  @doc "Admin-or-above check — the gate for admin-only actions (creating invites, etc.)."
  @spec admin?(atom()) :: boolean()
  def admin?(role), do: role in [:admin, :superadmin]
end
