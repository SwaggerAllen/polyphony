defmodule Polyphony.Moderation do
  @moduledoc """
  Reporting and moderation (§B3), built on the roles from §B2 and the ownership layer
  from §B1.

  Two guarantees hold across this module:

    * **Every admin action is server-side authorized** — never UI-gated only. A
      non-admin caller gets `{:error, :forbidden}` and **no side effect**: no state
      change and no audit row.
    * **Every admin action is audited and attributed** — one `AuditLog` row per
      successful action, especially any access to user content (`content_access`), the
      scoped, report-only access of §C.

  Filing a report is a *user* action (an authenticated reporter, `%User{}`); resolving
  one — view-in-context, take down, dismiss, warn, suspend — is an *admin* action. A
  new report fires the admin alert through the pluggable `Notifier` (the one live
  notification wire in v1; real email is B4).
  """

  require Logger

  alias Polyphony.{Repo, Library, Accounts}
  alias Polyphony.Accounts.{User, Roles}
  alias Polyphony.Moderation.{Report, AuditLog, Notifier}

  # ── Filing (a user action — authenticated reporter) ───────────────────────────

  @doc """
  File a report. `reporter` must be an authenticated `%User{}`. `attrs` carries
  `:item_type`, `:item_id`, `:owner_id`, `:reason` (a `Report.reasons/0` category),
  and `:detail`. Fires the admin alert. Returns `{:ok, report}` or a changeset error.
  """
  @spec file_report(User.t(), map(), keyword()) :: {:ok, Report.t()} | {:error, term()}
  def file_report(%User{} = reporter, attrs, opts \\ []) do
    attrs = attrs |> Map.new() |> Map.put(:reporter_id, reporter.id)

    case repo(opts).insert(Report.new_changeset(attrs)) do
      {:ok, report} ->
        notifier(opts).report_filed(report)
        {:ok, report}

      error ->
        error
    end
  end

  @doc """
  The queue, in lanes (`ux/polyphony-admin.html` §01).

  **Child safety is its own lane** — not a filter on a general queue but a separate
  list that is always first, always visible, and doesn't get buried under forty spam
  reports. Different urgency, different handling.

  Within a lane it's **oldest first**, because the alternative is reports that never
  get looked at.

  Returns `%{urgent:, forks:, rest:}` — the third lane is forks of things that were
  taken down, which are *review* rather than reports (§B3): a take-down spreads, and
  a fork may have diverged twenty scenes past anything objectionable.
  """
  @spec lanes(keyword()) :: %{urgent: [Report.t()], forks: [map()], rest: [Report.t()]}
  def lanes(opts \\ []) do
    {urgent, rest} =
      opts
      |> list_open()
      |> Enum.sort_by(& &1.inserted_at, NaiveDateTime)
      |> Enum.split_with(&Report.absolute_line?(&1.reason))

    %{urgent: urgent, forks: review_lane(opts), rest: rest}
  end

  @doc """
  Forks awaiting review after an ancestor was taken down.

  The design's third option, and the reason it exists: a take-down that fired a cascade
  would delete work that may contain none of what was reported, and one that ignored
  the family would leave the reported material sitting in every copy. So a take-down
  opens a lane, and somebody looks.
  """
  @spec review_lane(keyword()) :: [map()]
  def review_lane(opts \\ []) do
    for entry <- Library.hidden(opts), entry.review_reason == "fork_of_takedown" do
      %{entry: entry, root_id: Library.root_of(entry)}
    end
  end

  @doc "Clear a fork from the review lane — it diverged, and it stays up."
  def leave_fork(%User{} = admin, entry_id, opts \\ []) do
    with_admin(admin, "fork_cleared", {"library_entry", entry_id}, %{}, opts, fn ->
      Library.unhide(entry_id, opts)
    end)
  end

  @doc "Take a fork down too — it carries the same material."
  def take_down_fork(%User{} = admin, entry_id, reason, opts \\ []) do
    with_admin(admin, "takedown", {"library_entry", entry_id}, %{reason: reason}, opts, fn ->
      Library.hide(entry_id, reason, opts)
    end)
  end

  @doc "Reports that have been decided, newest first."
  @spec list_resolved(keyword()) :: [Report.t()]
  def list_resolved(opts \\ []) do
    import Ecto.Query

    repo(opts).all(from(r in Report, where: r.status != "open", order_by: [desc: r.resolved_at]))
  end

  @doc "Open reports, newest first."
  def list_open(opts \\ []) do
    import Ecto.Query
    repo(opts).all(from(r in Report, where: r.status == "open", order_by: [desc: r.inserted_at]))
  end

  def get_report(id, opts \\ []), do: repo(opts).get(Report, id)

  # ── Resolution (admin actions — authorized + audited) ─────────────────────────

  @doc """
  **View a report in context** — the §C reactive-access grant. Authorizes the admin,
  **audits the content access**, and returns the owning account's library entries.
  Reachable only via a report; the audit row is the accountability record.
  """
  def access_report_content(%User{} = admin, %Report{} = report, opts \\ []) do
    with_admin(
      admin,
      "content_access",
      {"report", report.id},
      # The stated reason is the accountability record. A reason field turns an
      # unlogged habit into a decision — nobody types one forty times a day for
      # something they don't need.
      %{owner_id: report.owner_id, why: Keyword.get(opts, :why)},
      opts,
      fn ->
        # The §C grant is the one read that sees past a take-down — reviewing what was
        # hidden is the whole point of it.
        {:ok, Library.list_for_owner(report.owner_id, Keyword.put(opts, :include_hidden, true))}
      end
    )
  end

  @doc """
  **Take down** the reported item: unpublish it (visibility → private), record the
  reason (shown to the owner), and mark the report actioned. An **absolute-line**
  report (CSAM / real-person sexual) additionally **flags the owning account** for
  review — the account, not just the item.
  """
  def take_down(%User{} = admin, %Report{} = report, reason, opts \\ []) do
    absolute = Report.absolute_line?(report.reason)

    with_admin(
      admin,
      "takedown",
      {"report", report.id},
      %{reason: reason, absolute_line: absolute},
      opts,
      fn ->
        unpublish(report, opts)
        # A take-down takes everything and **spreads**: the public copy and the
        # author's own, plus every fork descended from it. *She loses the campaign,
        # not just its listing* — so the author's copies go down with it, and only
        # other people's forks go to the review lane, because one may have diverged
        # past anything objectionable and can't be taken down blind.
        spread_takedown(report, reason, opts)
        if absolute and report.owner_id, do: flag_account(report.owner_id, opts)

        {:ok, resolve(report, "actioned", "takedown", reason, admin, opts)}
      end
    )
  end

  @doc "**Dismiss** a report — no violation. Marks it dismissed."
  def dismiss(%User{} = admin, %Report{} = report, opts \\ []) do
    with_admin(admin, "dismiss", {"report", report.id}, %{}, opts, fn ->
      {:ok, resolve(report, "dismissed", "dismiss", nil, admin, opts)}
    end)
  end

  @doc "**Warn** the owner. Notifies them and audits; leaves the report open for follow-up."
  def warn_owner(%User{} = admin, %Report{} = report, message, opts \\ []) do
    with_admin(admin, "warn", {"report", report.id}, %{message: message}, opts, fn ->
      notifier(opts).owner_warned(report, message)
      {:ok, report}
    end)
  end

  @doc """
  **Suspend** the reported account for `days` (nil = until we say otherwise).

  A person, not a thing — a separate action from a take-down with a separate confirm,
  because they have different consequences and different reversals. Nothing of theirs
  is deleted; they can't sign in or publish, and **everything they've shared goes
  dark, public and unlisted both**. Hiding the unlisted half is what stops a suspended
  person opening their own share link from a new account and forking their way back in.
  """
  @spec suspend_user(User.t(), Report.t(), pos_integer() | nil, keyword()) ::
          {:ok, Report.t()} | {:error, term()}
  def suspend_user(admin, report, days \\ nil, opts \\ [])

  def suspend_user(%User{} = admin, %Report{} = report, days, opts) do
    with_admin(
      admin,
      "suspend",
      {"user", report.owner_id},
      %{report_id: report.id, days: days},
      opts,
      fn ->
        case report.owner_id && Accounts.get(report.owner_id, opts) do
          %User{} = owner ->
            Accounts.suspend(owner, days, opts)
            hide_everything_shared(owner, "suspended", opts)
            {:ok, resolve(report, "actioned", "suspend", nil, admin, opts)}

          _ ->
            {:error, :no_owner}
        end
      end
    )
  end

  @doc """
  **Lift a suspension.** Reinstatement was never reachable, and an indefinite
  suspension with no way back is a deletion nobody agreed to.

  What comes back is what the owner chose: hiding never touched their `visibility`, so
  a public thing is public again and an unlisted one is unlisted again.
  """
  @spec lift_suspension(User.t(), User.t(), keyword()) :: {:ok, User.t()} | {:error, term()}
  def lift_suspension(%User{} = admin, %User{} = target, opts \\ []) do
    with_admin(admin, "reinstate", {"user", target.id}, %{}, opts, fn ->
      Accounts.reinstate(target, opts)

      for entry <- Library.hidden(opts),
          entry.review_reason == "suspended",
          to_string(entry.owner_id) == to_string(target.id) do
        Library.unhide(entry.id, opts)
      end

      {:ok, Accounts.get(target.id, opts)}
    end)
  end

  @doc """
  Everything a moderator has done lately, newest first — the audit view.

  Privilege use (reading an unpublished perspective) is the entry most likely to matter
  later and the least likely to be looked for, so the screen tints it; this read just
  makes sure it's *there*.
  """
  @spec recent_audit(keyword()) :: [AuditLog.t()]
  def recent_audit(opts \\ []),
    do: AuditLog.list_recent(repo(opts), Keyword.get(opts, :limit, 50))

  @doc """
  Somebody's whole history, **both directions**.

  Reports against them and reports they made, each with outcomes. The second direction
  is a signal too: someone whose reports are nearly all dismissed is campaigning rather
  than reporting, and a queue that only ever looks at the accused can't see that.
  """
  @spec history(term(), keyword()) :: map()
  def history(user_id, opts \\ []) do
    against = Report.list_for_owner(repo(opts), user_id)
    made = Report.list_by_reporter(repo(opts), user_id)

    %{
      against: against,
      against_upheld: Enum.count(against, &(&1.status == "actioned")),
      made: made,
      made_upheld: Enum.count(made, &(&1.status == "actioned")),
      made_dismissed: Enum.count(made, &(&1.status == "dismissed"))
    }
  end

  @doc """
  How many earlier reports on the same item were dismissed.

  Shown on a report because the fourth one on the same thing usually means somebody is
  campaigning rather than reporting.
  """
  @spec previous_dismissals(Report.t(), keyword()) :: non_neg_integer()
  def previous_dismissals(%Report{} = report, opts \\ []) do
    repo(opts)
    |> Report.list_for_item(report.item_type, report.item_id)
    |> Enum.count(&(&1.id != report.id and &1.status == "dismissed"))
  end

  # The reported thing goes dark, and so does everything of the **author's** it belongs
  # to — that is what "removes the thing, not its listing" means, and it's why the owner
  # gets the deleted experience rather than a private copy they can still open and
  # republish from.
  #
  # **Somebody else's fork is a different question**, so it goes dark *and* into a
  # review lane: it may have diverged twenty scenes past anything objectionable, and
  # taking it down blind would destroy work containing none of what was reported.
  defp spread_takedown(%Report{item_type: "library_entry", item_id: id} = report, reason, opts)
       when is_integer(id) do
    Library.hide(id, takedown_reason(reason), opts)

    for entry <- Library.family(id, opts), entry.id != id do
      if same_owner?(entry, report),
        do: Library.hide(entry.id, takedown_reason(reason), opts),
        else: Library.hide(entry.id, "fork_of_takedown", opts)
    end
  end

  defp spread_takedown(_report, _reason, _opts), do: :ok

  defp takedown_reason(reason) when is_binary(reason) and reason != "", do: reason
  defp takedown_reason(_reason), do: "takedown"

  defp same_owner?(entry, %Report{owner_id: owner_id}) when not is_nil(owner_id),
    do: to_string(entry.owner_id) == to_string(owner_id)

  defp same_owner?(_entry, _report), do: false

  defp hide_everything_shared(owner, reason, opts) do
    for entry <- Library.shared_by(owner, opts), do: Library.hide(entry.id, reason, opts)
  end

  @doc "The audit trail for an actor (accountability read)."
  def audit_trail(actor_id, opts \\ []), do: AuditLog.list_for_actor(repo(opts), actor_id)

  # ── Internals ─────────────────────────────────────────────────────────────────

  # Authorize first (no side effect if forbidden), run, then audit **only** a
  # successful action. A failed attempt writes nothing.
  defp with_admin(%User{} = actor, action, {target_type, target_id}, metadata, opts, fun) do
    if Roles.admin?(role_atom(actor.role)) do
      case fun.() do
        {:ok, _} = ok ->
          audit(actor, action, target_type, target_id, metadata, opts)
          ok

        other ->
          other
      end
    else
      {:error, :forbidden}
    end
  end

  defp audit(actor, action, target_type, target_id, metadata, opts) do
    AuditLog.put(repo(opts), %{
      actor_id: actor.id,
      action: action,
      target_type: target_type,
      target_id: target_id,
      metadata: stringify(metadata)
    })
  end

  defp unpublish(%Report{item_type: "library_entry", item_id: id}, opts) when not is_nil(id),
    do: Library.set_visibility(id, "private", opts)

  defp unpublish(_report, _opts), do: :ok

  defp flag_account(owner_id, opts) do
    case Accounts.get(owner_id, opts) do
      %User{} = owner -> Accounts.flag_for_review(owner, opts)
      _ -> :ok
    end
  end

  defp resolve(report, status, resolution, reason, admin, opts) do
    repo(opts).update!(
      Report.resolve_changeset(report, %{
        status: status,
        resolution: resolution,
        resolution_reason: reason,
        resolved_by_id: admin.id,
        resolved_at: now(opts)
      })
    )
  end

  defp repo(opts), do: Keyword.get(opts, :repo, Repo)

  defp notifier(opts), do: Keyword.get(opts, :notifier, Notifier.adapter())

  defp now(opts),
    do:
      Keyword.get_lazy(opts, :now, fn ->
        NaiveDateTime.truncate(NaiveDateTime.utc_now(), :microsecond)
      end)

  defp role_atom(role) when is_atom(role), do: role
  defp role_atom(role) when is_binary(role), do: String.to_existing_atom(role)

  # jsonb keys/values must be JSON-safe; stringify metadata values for the map column.
  defp stringify(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_value(v)} end)
  end

  defp stringify_value(v) when is_boolean(v) or is_number(v) or is_binary(v) or is_nil(v), do: v
  defp stringify_value(v), do: to_string(v)
end
