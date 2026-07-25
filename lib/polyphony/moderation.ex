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
      %{owner_id: report.owner_id},
      opts,
      fn ->
        {:ok, Library.list_for_owner(report.owner_id, opts)}
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

  @doc "**Suspend** the reported account. Suspends the owner and marks the report actioned."
  def suspend_user(%User{} = admin, %Report{} = report, opts \\ []) do
    with_admin(admin, "suspend", {"user", report.owner_id}, %{report_id: report.id}, opts, fn ->
      case report.owner_id && Accounts.get(report.owner_id, opts) do
        %User{} = owner ->
          Accounts.suspend(owner, opts)
          {:ok, resolve(report, "actioned", "suspend", nil, admin, opts)}

        _ ->
          {:error, :no_owner}
      end
    end)
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
