defmodule Polyphony.Accounts do
  @moduledoc """
  Identity, authorization, invites, and consent (§B2) — the account domain the
  ownership layer (§B1) attributes owned entities to.

  This is the **offline-testable core**. Magic-link login tokens, sessions with
  sliding renewal, and the numeric-code fallback are transport handled by the
  web/auth layer; everything that decides *who may do what* lives here and is tested
  without a browser:

    * **Gated sign-up** (`register/2`) — three preconditions, all enforced here: an
      18+ attestation (logged, the content floor of §A5), a valid single-use invite
      (except the very first account, which bootstraps as `superadmin`), and
      acceptance of the current consent documents.
    * **Roles** (planned addition #4) — first account is the sole, un-demotable
      `superadmin`; promotion/demotion is authorized by the pure `Accounts.Roles`
      and the singleton superadmin is also pinned by a DB constraint.
    * **Invites** (planned addition #5) — admin-generated, single-use.
    * **Consent** — versioned, append-only; `needs_reconsent?/2` re-prompts on a
      material version bump.

  Timestamps are read-model state (never event-sourced/replayed), so a wall clock is
  fine; `:now` is injectable for deterministic tests.
  """

  import Ecto.Query

  alias Polyphony.Repo
  alias Polyphony.Accounts.{User, Invite, Consent, Roles}

  # ── Reads ─────────────────────────────────────────────────────────────────────

  def get(id, opts \\ []), do: repo(opts).get(User, id)

  def get_by_email(email, opts \\ []),
    do: repo(opts).get_by(User, email: email |> to_string() |> String.downcase())

  def get_by_username(username, opts \\ []),
    do: repo(opts).get_by(User, username: to_string(username))

  def count(opts \\ []), do: repo(opts).aggregate(User, :count, :id)

  @doc "Has this account attested 18+? Its presence is the content floor (§A5)."
  @spec adult_attested?(User.t()) :: boolean()
  def adult_attested?(%User{attested_adult_at: at}), do: not is_nil(at)

  # ── Sign-up ─────────────────────────────────────────────────────────────────

  @doc """
  Register a new account, enforcing every sign-up gate. `attrs` needs `:email`,
  `:username`, `attested_adult: true`, and `accepted_consents:` covering every
  `Consent.required_documents/0`. A non-first sign-up also needs `invite_token:`.

  Returns `{:ok, user}`, or `{:error, reason}` where reason is
  `:attestation_required` / `:invite_required` / `:invite_invalid` /
  `:consent_required` / an `Ecto.Changeset` (email/username taken or malformed).
  """
  @spec register(map() | keyword(), keyword()) :: {:ok, User.t()} | {:error, term()}
  def register(attrs, opts \\ []) do
    repo = repo(opts)
    now = now(opts)
    attrs = Map.new(attrs)

    with :ok <- require_attestation(attrs),
         {:ok, role, invite} <- gate_signup(attrs, repo),
         :ok <- require_consents(attrs) do
      changeset =
        User.registration_changeset(
          attrs
          |> Map.put(:role, role)
          |> Map.put(:attested_adult_at, now)
        )

      case repo.insert(changeset) do
        {:ok, user} ->
          if invite, do: repo.update!(Invite.redeem_changeset(invite, user.id, now))
          record_consents(repo, user.id, now)
          {:ok, user}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  defp require_attestation(attrs) do
    if truthy?(Map.get(attrs, :attested_adult)), do: :ok, else: {:error, :attestation_required}
  end

  # First account bootstraps as superadmin and needs no invite; everyone else needs
  # a valid, unspent invite and starts a plain user.
  defp gate_signup(attrs, repo) do
    if repo.aggregate(User, :count, :id) == 0 do
      {:ok, "superadmin", nil}
    else
      case find_open_invite(attrs, repo) do
        {:ok, invite} -> {:ok, "user", invite}
        error -> error
      end
    end
  end

  defp find_open_invite(attrs, repo) do
    case Map.get(attrs, :invite_token) do
      nil ->
        {:error, :invite_required}

      token ->
        case repo.get_by(Invite, token: to_string(token)) do
          nil ->
            {:error, :invite_invalid}

          invite ->
            if Invite.redeemed?(invite), do: {:error, :invite_invalid}, else: {:ok, invite}
        end
    end
  end

  defp require_consents(attrs) do
    accepted = attrs |> Map.get(:accepted_consents, []) |> Enum.map(&to_string/1) |> MapSet.new()
    required = Consent.required_documents() |> Enum.map(&to_string/1) |> MapSet.new()
    if MapSet.subset?(required, accepted), do: :ok, else: {:error, :consent_required}
  end

  defp record_consents(repo, user_id, now) do
    for {document, version} <- Consent.documents() do
      repo.insert!(Consent.changeset(user_id, document, version, now))
    end
  end

  # ── Roles (planned addition #4) ───────────────────────────────────────────────

  @doc """
  Change `target`'s role, authorized by `actor`. Enforces the pure `Roles` rules —
  superadmin is un-demotable and never assignable, promotion to admin needs an
  admin/superadmin actor, demotion needs the superadmin. Returns `{:ok, user}` or
  `{:error, :forbidden}`.
  """
  @spec set_role(User.t(), User.t(), atom() | String.t(), keyword()) ::
          {:ok, User.t()} | {:error, :forbidden}
  def set_role(%User{} = actor, %User{} = target, new_role, opts \\ []) do
    new = role_atom(new_role)

    if Roles.can_change_role?(role_atom(actor.role), role_atom(target.role), new) do
      {:ok, repo(opts).update!(User.role_changeset(target, new))}
    else
      {:error, :forbidden}
    end
  end

  @doc "Promote `target` to admin (convenience over `set_role/4`)."
  def promote_to_admin(actor, target, opts \\ []), do: set_role(actor, target, :admin, opts)

  @doc "Demote `target` to user (convenience over `set_role/4`)."
  def demote_to_user(actor, target, opts \\ []), do: set_role(actor, target, :user, opts)

  # ── Invites (planned addition #5) ─────────────────────────────────────────────

  @doc "Mint a single-use invite. Admin-or-above only; returns `{:ok, invite} | {:error, :forbidden}`."
  @spec create_invite(User.t(), keyword()) :: {:ok, Invite.t()} | {:error, :forbidden}
  def create_invite(%User{} = actor, opts \\ []) do
    if Roles.admin?(role_atom(actor.role)) do
      {:ok, repo(opts).insert!(Invite.new_changeset(gen_token(), actor.id))}
    else
      {:error, :forbidden}
    end
  end

  @doc "An unredeemed invite for `token`, or nil."
  def open_invite(token, opts \\ []) do
    case repo(opts).get_by(Invite, token: to_string(token)) do
      nil -> nil
      invite -> if Invite.redeemed?(invite), do: nil, else: invite
    end
  end

  # ── Profile / username ─────────────────────────────────────────────────────────

  @doc "Update profile fields (never email or role)."
  def update_profile(%User{} = user, attrs, opts \\ []),
    do: repo(opts).update(User.profile_changeset(user, attrs))

  @username_change_interval_seconds 30 * 24 * 60 * 60

  @doc "May `user` change their username yet? Rate-limited to one change per 30 days."
  def can_change_username?(%User{username_changed_at: nil}, _now), do: true

  def can_change_username?(%User{username_changed_at: last}, now),
    do: NaiveDateTime.diff(now, last) >= @username_change_interval_seconds

  @doc """
  Change a username if the rate limit allows. Returns `{:ok, user}`, `{:error,
  :rate_limited}`, or an `Ecto.Changeset` on a taken/invalid handle.
  """
  def change_username(%User{} = user, new_username, opts \\ []) do
    now = now(opts)

    if can_change_username?(user, now) do
      repo(opts).update(
        User.username_changeset(user, %{username: new_username, username_changed_at: now})
      )
    else
      {:error, :rate_limited}
    end
  end

  # ── Consent ─────────────────────────────────────────────────────────────────

  @doc "Record acceptance of `document` at its current version for `user_id`."
  def accept_consent(user_id, document, opts \\ []) do
    version = Consent.current_version(document)
    repo(opts).insert!(Consent.changeset(user_id, document, version, now(opts)))
  end

  @doc "The latest accepted version per document for `user_id`."
  @spec accepted_versions(term(), keyword()) :: %{String.t() => pos_integer()}
  def accepted_versions(user_id, opts \\ []) do
    repo(opts).all(
      from(c in Consent,
        where: c.user_id == ^user_id,
        group_by: c.document,
        select: {c.document, max(c.version)}
      )
    )
    |> Map.new()
  end

  @doc """
  Which documents `user_id` must re-consent to — never accepted, or accepted at an
  older version than the current one. Empty means fully consented (§B2 re-prompt).
  """
  @spec needs_reconsent?(term(), keyword()) :: [atom()]
  def needs_reconsent?(user_id, opts \\ []) do
    accepted = accepted_versions(user_id, opts)

    for {document, current} <- Consent.documents(),
        Map.get(accepted, to_string(document), 0) < current,
        do: document
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp repo(opts), do: Keyword.get(opts, :repo, Repo)

  defp now(opts),
    do:
      Keyword.get_lazy(opts, :now, fn ->
        NaiveDateTime.truncate(NaiveDateTime.utc_now(), :microsecond)
      end)

  defp role_atom(role) when is_atom(role), do: role
  defp role_atom(role) when is_binary(role), do: String.to_existing_atom(role)

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  # A read-model token (never replayed), so a strong random value is appropriate.
  defp gen_token, do: 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
