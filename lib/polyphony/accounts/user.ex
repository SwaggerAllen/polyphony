defmodule Polyphony.Accounts.User do
  @moduledoc """
  An account (§B2). Identity is a **username** (unique, the public handle for owner
  attribution) kept distinct from **email** (auth-only — it must never appear on a
  profile or owner surface). `role` is the authorization tier (planned addition #4);
  `attested_adult_at` records the 18+ attestation whose presence gates account
  creation and is the content floor (§A5).

  Magic-link login tokens and sessions are transport, handled by the web/auth layer;
  this schema is the persisted identity the domain reasons about offline.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @roles ~w(user admin superadmin)

  schema "users" do
    field(:email, :string)
    field(:username, :string)
    field(:display_name, :string)
    field(:avatar_url, :string)
    field(:bio, :string)
    field(:role, :string, default: "user")
    field(:attested_adult_at, :naive_datetime_usec)
    field(:username_changed_at, :naive_datetime_usec)
    # Moderation state (§B3): suspension gates login; a review flag is raised by an
    # absolute-line takedown against this account's content.
    field(:suspended_at, :naive_datetime_usec)
    field(:flagged_for_review_at, :naive_datetime_usec)
    timestamps(type: :naive_datetime_usec)
  end

  @doc "Changeset for a new account — email + username required, both normalized and unique."
  def registration_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :email,
      :username,
      :display_name,
      :avatar_url,
      :bio,
      :role,
      :attested_adult_at
    ])
    |> validate_required([:email, :username, :role, :attested_adult_at])
    |> normalize_email()
    |> validate_username()
    |> validate_inclusion(:role, @roles)
    |> unique_constraint(:email)
    |> unique_constraint(:username)
    # Pins the singleton superadmin at the data layer — a second one fails here as a
    # graceful changeset error rather than a raised constraint violation.
    |> unique_constraint(:role, name: :one_superadmin, message: "superadmin already exists")
  end

  @doc "Changeset for a profile edit — never touches email or role."
  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, [:display_name, :avatar_url, :bio])
  end

  @doc "Changeset for a username change (the rate-limit anchor is stamped by the context)."
  def username_changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :username_changed_at])
    |> validate_required([:username])
    |> validate_username()
    |> unique_constraint(:username)
  end

  @doc "Changeset for a role change (authorization is enforced in `Accounts`/`Roles`)."
  def role_changeset(user, role) do
    user
    |> change(role: to_string(role))
    |> validate_inclusion(:role, @roles)
  end

  defp normalize_email(changeset) do
    update_change(changeset, :email, fn email -> email |> to_string() |> String.downcase() end)
  end

  defp validate_username(changeset) do
    changeset
    |> validate_length(:username, min: 3, max: 32)
    |> validate_format(:username, ~r/^[a-zA-Z0-9_]+$/,
      message: "may only contain letters, numbers, and underscores"
    )
  end
end
