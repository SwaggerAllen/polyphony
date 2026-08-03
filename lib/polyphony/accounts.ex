defmodule Polyphony.Accounts do
  @moduledoc """
  Identity, authorization, invites, and consent (§B2) — the account domain the
  ownership layer (§B1) attributes owned entities to.

  This is the **offline-testable core**. Magic-link login tokens, sessions with
  sliding renewal, and the numeric-code fallback are transport handled by the
  web/auth layer; everything that decides *who may do what* lives here and is tested
  without a browser:

    * **Gated sign-up** (`register/2`) — three preconditions, all enforced here: an
      18+ attestation (**eligibility to hold an account, not a content ceiling** —
      backlog §4b.1), a valid single-use invite (except the very first account, which
      bootstraps as `superadmin`), and acceptance of the current consent documents.
      Attestation is checked *before* any write, so a refusal creates no user row and
      does not redeem the invite (§4b.1).
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
    do: repo(opts).get_by(User, email: normalize_email(email))

  @doc """
  The canonical form of an address: trimmed and lower-cased.

  **Trimmed** matters as much as the case: a phone keyboard readily leaves a trailing
  space on an autocompleted address, and sign-in is a silent lookup — no match simply
  produces no email, with a screen that says one was sent either way.
  """
  @spec normalize_email(term()) :: String.t()
  def normalize_email(email), do: email |> to_string() |> String.trim() |> String.downcase()

  @doc """
  Find an account by its public handle, or nil.

  Trimmed, then matched exactly. If that misses, a case-insensitive match is tried and
  **only answered when it is unambiguous** — usernames are stored case-sensitively (the
  unique index is on the raw value), so `Allen` and `allen` can both exist and picking
  one would be picking at random.

  The fallback exists for phones: a keyboard autocapitalises the first letter of a text
  field by default, which is enough to make your own handle not find you.
  """
  @spec get_by_username(term(), keyword()) :: User.t() | nil
  def get_by_username(username, opts \\ []) do
    repo = repo(opts)
    name = username |> to_string() |> String.trim()

    repo.get_by(User, username: name) || unique_by_case(repo, name)
  end

  defp unique_by_case(_repo, ""), do: nil

  defp unique_by_case(repo, name) do
    lowered = String.downcase(name)

    query =
      from(u in User, where: fragment("lower(?)", u.username) == ^lowered, limit: 2)

    case repo.all(query) do
      [user] -> user
      _ -> nil
    end
  end

  @doc """
  Find an account by **either** identifier — the sign-in lookup.

  Email first, then handle. Sign-in moved to email-only, which locks out anyone whose
  account predates that and who remembers a handle instead; the magic link still goes
  to the account's email either way, so accepting both costs nothing.
  """
  @spec get_by_login(term(), keyword()) :: User.t() | nil
  def get_by_login(identifier, opts \\ []),
    do: get_by_email(identifier, opts) || get_by_username(identifier, opts)

  def count(opts \\ []), do: repo(opts).aggregate(User, :count, :id)

  @doc "Every admin-or-above account (the report-alert recipients, §B4)."
  @spec list_admins(keyword()) :: [User.t()]
  def list_admins(opts \\ []),
    do: repo(opts).all(from(u in User, where: u.role in ["admin", "superadmin"]))

  @doc """
  Has this account attested 18+? True for every real account — attestation gates
  sign-up (backlog §4b.1), so it is eligibility, not a per-user content ceiling.
  Retained for the content-floor seam and future under-18 support.
  """
  @spec adult_attested?(User.t()) :: boolean()
  def adult_attested?(%User{attested_adult_at: at}), do: not is_nil(at)

  @doc "Is this account suspended? (Login gate lives in the web layer; this is the state.)"
  @spec suspended?(User.t()) :: boolean()
  def suspended?(%User{suspended_at: at}), do: not is_nil(at)

  @doc "Is this account flagged for review (e.g. by an absolute-line takedown, §B3)?"
  @spec flagged_for_review?(User.t()) :: boolean()
  def flagged_for_review?(%User{flagged_for_review_at: at}), do: not is_nil(at)

  @doc """
  Suspend for `days`, or indefinitely when `days` is nil — the design's *until we say
  otherwise*, which is a real choice rather than the only one.

  Authorization is the **caller's** responsibility (`Polyphony.Moderation` gates and
  audits these); this and its neighbours are plain identity-state writes, kept here
  because `Accounts` owns the user record.
  """
  def suspend(user, days \\ nil, opts \\ [])

  def suspend(%User{} = user, days, opts) do
    now = now(opts)
    until = days && NaiveDateTime.add(now, days * 24 * 60 * 60, :second)

    repo(opts).update!(Ecto.Changeset.change(user, suspended_at: now, suspended_until: until))
  end

  def reinstate(%User{} = user, opts \\ []),
    do: repo(opts).update!(Ecto.Changeset.change(user, suspended_at: nil, suspended_until: nil))

  @doc """
  Is the suspension still running? A lapsed one is over whether or not anybody lifted it.

  Read rather than swept, so a `suspended_until` in the past simply stops binding —
  there is no window in which somebody stays locked out because a job hasn't run.
  """
  @spec suspension_active?(User.t(), keyword()) :: boolean()
  def suspension_active?(user, opts \\ [])
  def suspension_active?(%User{suspended_at: nil}, _opts), do: false
  def suspension_active?(%User{suspended_until: nil}, _opts), do: true

  def suspension_active?(%User{suspended_until: until}, opts),
    do: NaiveDateTime.compare(until, now(opts)) == :gt

  @doc "Days left on a suspension — nil when indefinite or not suspended."
  @spec suspension_days_left(User.t(), keyword()) :: non_neg_integer() | nil
  def suspension_days_left(user, opts \\ [])
  def suspension_days_left(%User{suspended_at: nil}, _opts), do: nil
  def suspension_days_left(%User{suspended_until: nil}, _opts), do: nil

  def suspension_days_left(%User{suspended_until: until}, opts) do
    seconds = NaiveDateTime.diff(until, now(opts), :second)
    if seconds <= 0, do: 0, else: ceil(seconds / 86_400)
  end

  @doc "Every currently-suspended account."
  @spec list_suspended(keyword()) :: [User.t()]
  def list_suspended(opts \\ []) do
    import Ecto.Query

    repo(opts).all(from(u in User, where: not is_nil(u.suspended_at)))
    |> Enum.filter(&suspension_active?(&1, opts))
  end

  def flag_for_review(%User{} = user, opts \\ []),
    do: repo(opts).update!(Ecto.Changeset.change(user, flagged_for_review_at: now(opts)))

  @doc "Has this account opted out of proactive analysis (§C)? Reactive access ignores this."
  @spec proactive_opted_out?(User.t()) :: boolean()
  def proactive_opted_out?(%User{proactive_opt_out_at: at}), do: not is_nil(at)

  @doc "Set/clear the account's proactive-analysis opt-out (§C)."
  def set_proactive_opt_out(%User{} = user, opted_out?, opts \\ []) do
    at = if opted_out?, do: now(opts), else: nil
    repo(opts).update!(Ecto.Changeset.change(user, proactive_opt_out_at: at))
  end

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

      # Atomic: the user, invite redemption, and consent records land together or
      # not at all — a mid-write failure never leaves a partial account behind (which
      # would then block retries on the unique email/username).
      repo.transaction(fn ->
        case repo.insert(changeset) do
          {:ok, user} ->
            if invite, do: repo.update!(Invite.redeem_changeset(invite, user.id, now))
            record_consents(repo, user.id, now)
            user

          {:error, changeset} ->
            repo.rollback(changeset)
        end
      end)
    end
  end

  @doc """
  Clean up a **failed bootstrap**. A "complete" account has at least one recorded
  consent (`register/2` writes the user + consents atomically). If any complete
  account exists, the bootstrap succeeded and this is a no-op. Otherwise nobody has
  finished signing up, so any partial user rows left by an earlier crash are deleted
  — letting the very next sign-up bootstrap the superadmin cleanly.

  Returns `{:ok, :bootstrap_complete}` or `{:ok, {:cleaned, count}}`.
  """
  def clean_incomplete_bootstrap(opts \\ []) do
    repo = repo(opts)

    if repo.exists?(Consent) do
      {:ok, :bootstrap_complete}
    else
      {count, _} = repo.delete_all(User)
      {:ok, {:cleaned, count}}
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

  @doc "Every invite, newest first — used and unused both, so the admin screen can show who came in through which."
  @spec list_invites(keyword()) :: [Invite.t()]
  def list_invites(opts \\ []) do
    import Ecto.Query
    repo(opts).all(from(i in Invite, order_by: [desc: i.inserted_at]))
  end

  @doc "An unredeemed invite for `token`, or nil."
  def open_invite(token, opts \\ []) do
    case repo(opts).get_by(Invite, token: to_string(token)) do
      nil -> nil
      invite -> if Invite.redeemed?(invite), do: nil, else: invite
    end
  end

  # ── Profile / username ─────────────────────────────────────────────────────────

  @doc """
  Set this account's own daily spend ceiling, in micro-cents.

  Passing `nil` puts them back on the configured default rather than on zero — the two
  are very different answers and only one of them is a setting anybody wants.
  """
  @spec set_daily_cap(User.t(), integer() | nil, keyword()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def set_daily_cap(%User{} = user, cap, opts \\ []) do
    cap = if is_integer(cap) and cap > 0, do: cap, else: nil

    user
    |> Ecto.Changeset.change(daily_cap: cap)
    |> repo(opts).update()
  end

  # ── Leaving ──────────────────────────────────────────────────────────────────

  @doc """
  How long a deleted account waits before it really goes. The same window as the
  library's trash (§2.13), for the same reason: the number has to mean something.
  """
  @spec deletion_window_days() :: pos_integer()
  def deletion_window_days, do: 30

  @doc """
  Ask for the account to be deleted — a decision on a clock, not an event.

  Nothing is destroyed here. *Sign back in within 30 days and none of this happens*,
  which is the whole design of it: leaving in anger is common and irreversible deletion
  of somebody's authored work is not something to do on a single tap.
  """
  @spec request_deletion(User.t(), keyword()) :: {:ok, User.t()} | {:error, term()}
  def request_deletion(%User{} = user, opts \\ []) do
    user
    |> Ecto.Changeset.change(deletion_requested_at: now(opts))
    |> repo(opts).update()
  end

  @doc "Change your mind. Called on sign-in too, which is what makes the promise true."
  @spec cancel_deletion(User.t(), keyword()) :: {:ok, User.t()} | {:error, term()}
  def cancel_deletion(user, opts \\ [])
  def cancel_deletion(%User{deletion_requested_at: nil} = user, _opts), do: {:ok, user}

  def cancel_deletion(%User{} = user, opts) do
    user
    |> Ecto.Changeset.change(deletion_requested_at: nil)
    |> repo(opts).update()
  end

  @doc "Is this account on its way out, and how many days are left?"
  @spec days_until_deletion(User.t(), keyword()) :: non_neg_integer() | nil
  def days_until_deletion(user, opts \\ [])
  def days_until_deletion(%User{deletion_requested_at: nil}, _opts), do: nil

  def days_until_deletion(%User{deletion_requested_at: at}, opts) do
    elapsed = NaiveDateTime.diff(now(opts), at, :second)
    remaining = deletion_window_days() * 24 * 60 * 60 - elapsed

    if remaining <= 0, do: 0, else: ceil(remaining / (24 * 60 * 60))
  end

  @doc """
  Delete the accounts whose window has run out, and everything they own.

  The half that makes the countdown a number rather than a claim — the same argument as
  the library's trash (§2.13). Returns how many went.

  A **forked copy is not touched**: it lives in the forker's library with its own root
  (§3.1d), and deleting somebody else's work to honour this request would be the wrong
  trade. What goes is this account's own entries, published originals included.
  """
  @spec purge_expired_deletions(keyword()) :: non_neg_integer()
  def purge_expired_deletions(opts \\ []) do
    repo = repo(opts)
    cutoff = NaiveDateTime.add(now(opts), -deletion_window_days() * 24 * 60 * 60, :second)

    import Ecto.Query

    repo.all(
      from(u in User,
        where: not is_nil(u.deletion_requested_at) and u.deletion_requested_at < ^cutoff
      )
    )
    |> Enum.reduce(0, fn user, count ->
      case purge_account(user, opts) do
        :ok -> count + 1
        _ -> count
      end
    end)
  end

  @doc """
  Delete one account and its library outright. Irreversible; the window is the safety.
  """
  @spec purge_account(User.t(), keyword()) :: :ok | {:error, term()}
  def purge_account(%User{} = user, opts \\ []) do
    repo = repo(opts)

    Enum.each(
      Polyphony.Library.list_for_owner(
        Polyphony.Owner.of(user),
        # A purge has to be complete, moderation-hidden entries included.
        opts ++ [include_archived: true, include_deleted: true, include_hidden: true]
      ),
      fn entry ->
        Polyphony.Library.purge(entry.id, opts)
      end
    )

    repo.delete(user)
    :ok
  rescue
    error -> {:error, error}
  end

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
