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

  @typedoc "A user row. `Ecto.Schema` generates no `t/0`, so it is declared here."
  @type t :: %__MODULE__{}

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
    # When it lifts. Null with a live `suspended_at` is a genuinely indefinite
    # suspension — the design's *until we say otherwise* — rather than an oversight.
    field(:suspended_until, :naive_datetime_usec)
    field(:flagged_for_review_at, :naive_datetime_usec)
    # §C: account-level opt-out from proactive analysis (reactive/report access ignores it).
    field(:proactive_opt_out_at, :naive_datetime_usec)
    # The account's own daily spend ceiling in micro-cents (§B5). Null means "use the
    # configured default" — so a default stays a default rather than being frozen into
    # every row the day it was introduced.
    field(:daily_cap, :integer)
    # Leaving is a decision on a clock, not an event: signing back in inside the window
    # cancels it (`ux/polyphony-settings-auth.html` §04).
    field(:deletion_requested_at, :naive_datetime_usec)
    timestamps(type: :naive_datetime_usec)
  end

  # One statement of the rule, read by the validation, the two forms that state it, and
  # the `pattern` the browser enforces.
  @username_min 3
  @username_max 32
  @username_format ~r/^[a-zA-Z0-9_]+$/

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
    # Through `Accounts.normalize_email/1` so what is stored and what is looked up can
    # never diverge — they had, on whitespace.
    update_change(changeset, :email, &Polyphony.Accounts.normalize_email/1)
  end

  defp validate_username(changeset) do
    changeset
    |> validate_length(:username, min: @username_min, max: @username_max)
    |> validate_format(:username, @username_format,
      message: "may only contain letters, numbers, and underscores"
    )
  end

  @doc """
  The username rules, in the words a form should show **before** anything is typed.

  Here rather than in the template because there are two forms — sign-up and settings —
  and a rule stated separately in each is a rule that will disagree with the validation
  in at least one of them. Somebody finding out the constraint by tripping over it is
  the failure this exists to prevent, and two of them saying different things is worse.
  """
  @spec username_rule() :: String.t()
  def username_rule,
    do: "#{@username_min}–#{@username_max} characters. Letters, numbers and underscores only."

  @doc "The same rule as an HTML `pattern`, so the browser can say it without a round trip."
  @spec username_pattern() :: String.t()
  def username_pattern, do: "[A-Za-z0-9_]{#{@username_min},#{@username_max}}"

  @doc "Bounds for a form's `minlength`/`maxlength`."
  @spec username_length() :: {pos_integer(), pos_integer()}
  def username_length, do: {@username_min, @username_max}
end
