defmodule Polyphony.Accounts.Invite do
  @moduledoc """
  An invite link (§B2, planned addition #5). Sign-up is invite-only — except the very
  first account, which bootstraps the system — so LLM access is never handed out
  without an explicit invitation.

  ## Two kinds, one row

  A **single-use** invite redeems exactly once, stamped with who and when. That is the
  door, and it is the default.

  A **reusable** one never spends itself. It exists for hands-on testing, where the
  whole job is putting a second and third account on a build and the single-use rule
  turns every one of those into a trip back to the admin screen. `redeemed_by_id` and
  `redeemed_at` still record the *most recent* redemption — useful, but no longer the
  whole story, which is what `uses` is for.

  ## Revocation

  An invite that never spends itself is a standing hole in an invite-only gate, so it
  has to be closeable. `revoked_at` applies to both kinds, because a single-use invite
  sent to the wrong address had no way back either. Revoking is not deleting: the row
  stays, so an account that came in through it still has its provenance.
  """
  use Ecto.Schema
  import Ecto.Changeset
  @typedoc "A row of this table. `Ecto.Schema` generates no `t/0`, so it is declared here."
  @type t :: %__MODULE__{}

  schema "invites" do
    field(:token, :string)
    field(:reusable, :boolean, default: false)
    field(:uses, :integer, default: 0)
    field(:created_by_id, :id)
    field(:redeemed_by_id, :id)
    field(:redeemed_at, :naive_datetime_usec)
    field(:revoked_at, :naive_datetime_usec)
    timestamps(type: :naive_datetime_usec)
  end

  @doc "A fresh, unredeemed invite for `token`, created by `created_by_id`."
  def new_changeset(token, created_by_id, opts \\ []) do
    %__MODULE__{}
    |> change(token: token, created_by_id: created_by_id, reusable: opts[:reusable] == true)
    |> validate_required([:token])
    |> unique_constraint(:token)
  end

  @doc """
  Record a redemption by `user_id` at `now`.

  The same stamp for both kinds — what differs is whether it closes the invite, and
  that is `spent?/1`'s answer, not this one's.
  """
  def redeem_changeset(%__MODULE__{} = invite, user_id, now) do
    change(invite,
      redeemed_by_id: user_id,
      redeemed_at: now,
      uses: (invite.uses || 0) + 1
    )
  end

  @doc "Close an invite for good, without erasing where an existing account came from."
  def revoke_changeset(%__MODULE__{} = invite, now), do: change(invite, revoked_at: now)

  @doc "Has this invite already been spent?"
  def redeemed?(%__MODULE__{redeemed_at: nil}), do: false
  def redeemed?(%__MODULE__{}), do: true

  @doc """
  Can this invite still be redeemed?

  The gate `Accounts` actually asks. Revoked is closed either way; otherwise a reusable
  invite is always open and a single-use one is open until it is redeemed.
  """
  def spent?(%__MODULE__{revoked_at: at}) when not is_nil(at), do: true
  def spent?(%__MODULE__{reusable: true}), do: false
  def spent?(%__MODULE__{} = invite), do: redeemed?(invite)
end
