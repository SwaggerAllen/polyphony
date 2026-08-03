defmodule Polyphony.Accounts.Invite do
  @moduledoc """
  A single-use invite link (§B2, planned addition #5). Sign-up is invite-only —
  except the very first account, which bootstraps the system — so LLM access is
  never handed out without an explicit invitation. An invite redeems **exactly
  once**; the redemption is stamped with who and when.
  """
  use Ecto.Schema
  import Ecto.Changeset
  @typedoc "A row of this table. `Ecto.Schema` generates no `t/0`, so it is declared here."
  @type t :: %__MODULE__{}

  schema "invites" do
    field(:token, :string)
    field(:created_by_id, :id)
    field(:redeemed_by_id, :id)
    field(:redeemed_at, :naive_datetime_usec)
    timestamps(type: :naive_datetime_usec)
  end

  @doc "A fresh, unredeemed invite for `token`, created by `created_by_id`."
  def new_changeset(token, created_by_id) do
    %__MODULE__{}
    |> change(token: token, created_by_id: created_by_id)
    |> validate_required([:token])
    |> unique_constraint(:token)
  end

  @doc "Mark an invite redeemed by `user_id` at `now` — single-use is enforced by the context."
  def redeem_changeset(%__MODULE__{} = invite, user_id, now) do
    change(invite, redeemed_by_id: user_id, redeemed_at: now)
  end

  @doc "Has this invite already been spent?"
  def redeemed?(%__MODULE__{redeemed_at: nil}), do: false
  def redeemed?(%__MODULE__{}), do: true
end
